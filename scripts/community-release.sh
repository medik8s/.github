#!/usr/bin/env bash
# community-release.sh — Automate community operator releases for medik8s operators.
#
# Usage:
#   ./community-release.sh [--dry-run] [--step tag|build|community|prs] <config-file>
#
# Config file is a YAML file. See release.conf.yaml.example for format.

set -euo pipefail

# ── Operator repository mapping ──────────────────────────────────────────────
declare -A OP_REPO=(
    [SNR]=self-node-remediation
    [FAR]=fence-agents-remediation
    [NMO]=node-maintenance-operator
    [NHC]=node-healthcheck-operator
    [MDR]=machine-deletion-remediation
)

declare -A OP_DISPLAY=()
declare -A OP_QUAY_IMAGE=()
declare -A OP_WORKFLOW=()

DRY_RUN=false
STEP=all          # tag, build, community, prs, or all
CONFIG_FILE=""

# ── Config state ─────────────────────────────────────────────────────────────
CONFIG_YAML=""
RELEASE_COUNT=0
declare -a RELEASE_NEEDS_BUILD=()   # runtime-computed, not from config

declare -a PR_URLS=()

log()   { echo "==> $*"; }
step()  { printf "\n==> Step: %s\n" "$*"; }
info()  { echo "    $*"; }
warn()  { echo "WARNING: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# ── Config accessors ─────────────────────────────────────────────────────────

release_field() {
    echo "$CONFIG_YAML" | yq e ".releases[$1].$2 // \"\""
}

release_targets() {
    echo "$CONFIG_YAML" | yq e '(.releases['"$1"'].targets // ["k8s","okd"]) | join(" ")'
}

release_ocp_version() {
    echo "$CONFIG_YAML" | yq e ".releases[$1].ocp_version // \"\""
}

release_downstream_version() {
    echo "$CONFIG_YAML" | yq e ".releases[$1].downstream_version // .releases[$1].version"
}

release_targets_k8s() {
    local targets
    targets=$(release_targets "$1")
    [[ " $targets " == *" k8s "* ]]
}

release_targets_okd() {
    local targets
    targets=$(release_targets "$1")
    [[ " $targets " == *" okd "* ]]
}

# ── Utilities ────────────────────────────────────────────────────────────────

run() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] $*"
        return 0
    fi
    "$@" > /dev/null
}

capture_run_id() {
    local op="$1" repo="$2" workflow="$3" label="$4"
    sleep 5
    local run_id
    run_id=$(gh run list --repo "medik8s/${repo}" --workflow="$workflow" --limit 1 --json databaseId --jq '.[0].databaseId')
    if [[ -n "$run_id" ]]; then
        # run_ids and run_repos are caller-declared arrays used as return values
        run_ids+=("$run_id")
        run_repos+=("medik8s/${repo}")
        info "[$op] ${label} workflow run: https://github.com/medik8s/${repo}/actions/runs/${run_id}"
    else
        warn "[$op] Could not capture run ID"
    fi
}

version_lt() {
    local -a a b  # arrays for version components
    local i        # loop counter — cannot use -a here (scalar, not array)
    IFS=. read -ra a <<< "$1"
    IFS=. read -ra b <<< "$2"
    for i in 0 1 2; do
        if (( ${a[$i]:-0} < ${b[$i]:-0} )); then return 0; fi
        if (( ${a[$i]:-0} > ${b[$i]:-0} )); then return 1; fi
    done
    return 1
}

gh_tag_exists() {
    gh api "repos/${1}/git/refs/tags/${2}" &>/dev/null
}

quay_tag_exists() {
    local repo="$1" tag="$2"
    local response
    response=$(curl -sf "https://quay.io/api/v1/repository/medik8s/${repo}/tag/?specificTag=${tag}&onlyActiveTags=true" 2>/dev/null) || return 1
    local count
    count=$(echo "$response" | yq e '.tags | length' 2>/dev/null) || return 1
    [[ "$count" -gt 0 ]]
}

version_already_released() {
    local target_repo="$1" repo="$2" version="$3" previous="$4"

    gh api "repos/${target_repo}/contents/operators/${repo}/${version}" &>/dev/null || return 1

    if [[ "$target_repo" == "redhat-openshift-ecosystem/community-operators-prod" ]]; then
        local csv_path="repos/${target_repo}/contents/operators/${repo}/${version}/manifests/${repo}.clusterserviceversion.yaml"
        local csv_content
        csv_content=$(gh api "$csv_path" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null) || return 0
        local replaces_line
        replaces_line=$(echo "$csv_content" | grep "^  replaces:" 2>/dev/null || true)
        if [[ -n "$replaces_line" ]]; then
            local expected="replaces: ${repo}.v${previous}"
            if ! echo "$replaces_line" | grep -q "$expected"; then
                local actual="${replaces_line#*: }"
                warn "[$repo] Released CSV replaces '${actual}' does not match expected '${repo}.v${previous}'"
            fi
        fi
    fi

    return 0
}

community_branch_exists() {
    gh api "repos/${1}/git/refs/heads/${2}" &>/dev/null
}

# ── Config loading ───────────────────────────────────────────────────────────

parse_yaml_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "Config file not found: $CONFIG_FILE"
    fi

    CONFIG_YAML=$(cat "$CONFIG_FILE")
    RELEASE_COUNT=$(echo "$CONFIG_YAML" | yq e '.releases | length' 2>/dev/null) || die "Invalid YAML config file: $CONFIG_FILE"
    if [[ "$RELEASE_COUNT" -eq 0 || "$RELEASE_COUNT" == "null" ]]; then
        die "No release entries in config. Nothing to do."
    fi
}

init_operator_metadata() {
    local -A seen=()
    for ((i=0; i<RELEASE_COUNT; i++)); do
        local op
        op=$(release_field "$i" operator)
        [[ -z "${seen[$op]:-}" ]] || continue
        seen[$op]=1

        local repo="${OP_REPO[$op]:-}"
        [[ -n "$repo" ]] || die "Unknown operator: $op"

        if [[ "$repo" == *-operator ]]; then
            OP_QUAY_IMAGE[$op]="$repo"
        else
            OP_QUAY_IMAGE[$op]="${repo}-operator"
        fi

        local display=""
        local -a words
        IFS='-' read -ra words <<< "${OP_QUAY_IMAGE[$op]}"
        for word in "${words[@]}"; do
            display+="${word^} "
        done
        OP_DISPLAY[$op]="${display% }"
    done
}

detect_release_workflows() {
    local -A seen=()
    for ((i=0; i<RELEASE_COUNT; i++)); do
        local op
        op=$(release_field "$i" operator)
        [[ -z "${seen[$op]:-}" ]] || continue
        seen[$op]=1

        local repo="${OP_REPO[$op]}"
        if gh api "repos/medik8s/${repo}/contents/.github/workflows/release.yml" &>/dev/null; then
            OP_WORKFLOW[$op]="release.yml"
        elif gh api "repos/medik8s/${repo}/contents/.github/workflows/release.yaml" &>/dev/null; then
            OP_WORKFLOW[$op]="release.yaml"
        else
            die "[$op] No release workflow found on medik8s/${repo} (tried release.yml and release.yaml)"
        fi
    done
}

# ── Validation ───────────────────────────────────────────────────────────────

validate_config() {
    log "Validating configuration"

    for cmd in gh git curl yq; do
        if ! command -v "$cmd" &>/dev/null; then
            die "'$cmd' is required but not found in PATH"
        fi
    done
    info "Required tools: OK"

    if ! gh auth status &>/dev/null; then
        die "GitHub (gh) CLI is not authenticated. Run 'gh auth login' first."
    fi
    info "GitHub (gh) CLI: OK"

    parse_yaml_config

    for ((i=0; i<RELEASE_COUNT; i++)); do
        local op version previous
        op=$(release_field "$i" operator)
        version=$(release_field "$i" version)
        previous=$(release_field "$i" previous)

        if [[ -z "${OP_REPO[$op]:-}" ]]; then
            die "releases[$i]: unknown operator '$op'"
        fi

        if [[ -z "$version" || "$version" == "null" ]]; then
            die "releases[$i] ($op): version is required"
        fi

        if [[ -z "$previous" || "$previous" == "null" ]]; then
            die "releases[$i] ($op): previous is required"
        fi

        if ! version_lt "$previous" "$version"; then
            die "releases[$i] ($op): previous ($previous) must be lower than version ($version)"
        fi

        local targets
        targets=$(release_targets "$i")
        for t in $targets; do
            case "$t" in
                k8s|okd) ;;
                *) die "releases[$i] ($op): invalid target '$t' (must be k8s or okd)" ;;
            esac
        done

        if release_targets_okd "$i" && [[ -z "$(release_ocp_version "$i")" ]]; then
            die "releases[$i] ($op): ocp_version is required when targets includes okd"
        fi

        local srl
        srl=$(release_field "$i" skip_range_lower)

        local repo="${OP_REPO[$op]}"
        local quay_image="${OP_QUAY_IMAGE[$op]:-}"
        [[ -n "$quay_image" ]] || {
            if [[ "$repo" == *-operator ]]; then quay_image="$repo"; else quay_image="${repo}-operator"; fi
        }
        local prev_tag="v${previous}"
        local ver_tag="v${version}"

        if ! gh_tag_exists "medik8s/${repo}" "$prev_tag"; then
            die "releases[$i] ($op): previous version tag $prev_tag does not exist on medik8s/${repo}"
        fi

        if [[ "$STEP" != "tag" ]]; then
            local bundle_image="${quay_image}-bundle"
            if ! quay_tag_exists "$quay_image" "$prev_tag" || ! quay_tag_exists "$bundle_image" "$prev_tag"; then
                die "releases[$i] ($op): previous version images quay.io/medik8s/${quay_image}:${prev_tag} or quay.io/medik8s/${bundle_image}:${prev_tag} not found"
            fi

            local has_operator has_bundle
            has_operator=$(quay_tag_exists "$quay_image" "$ver_tag" && echo yes || echo no)
            has_bundle=$(quay_tag_exists "$bundle_image" "$ver_tag" && echo yes || echo no)

            if [[ "$has_operator" == "yes" && "$has_bundle" == "yes" ]]; then
                info "releases[$i] ($op): images quay.io/medik8s/${quay_image}:${ver_tag} and bundle already exist — build_and_push will be skipped"
                RELEASE_NEEDS_BUILD[$i]=no
            elif [[ "$has_operator" == "yes" || "$has_bundle" == "yes" ]]; then
                warn "releases[$i] ($op): partial build detected: operator=${has_operator} bundle=${has_bundle} on quay.io for ${ver_tag}"
                RELEASE_NEEDS_BUILD[$i]=partial
            else
                RELEASE_NEEDS_BUILD[$i]=yes
            fi
        fi
    done

    init_operator_metadata
    detect_release_workflows

    log "Configuration summary"
    echo ""
    printf "    %-6s %-10s %-10s %-10s %-12s %s\n" "OP" "VERSION" "PREVIOUS" "TARGETS" "OCP_VERSION" "EXTRA"
    printf "    %-6s %-10s %-10s %-10s %-12s %s\n" "----" "-------" "--------" "-------" "-----------" "-----"
    for ((i=0; i<RELEASE_COUNT; i++)); do
        local op version targets ocp_version ds_ver srl commit extra
        op=$(release_field "$i" operator)
        version=$(release_field "$i" version)
        targets=$(release_targets "$i")
        ocp_version=$(release_ocp_version "$i")
        ds_ver=$(release_downstream_version "$i")
        srl=$(release_field "$i" skip_range_lower)
        commit=$(release_field "$i" commit)
        extra=""
        [[ -z "$srl" ]] || extra="skip_range_lower=${srl}"
        [[ "$ds_ver" == "$version" ]] || extra="${extra:+$extra }downstream=${ds_ver}"
        [[ -z "$commit" ]] || extra="${extra:+$extra }commit=${commit}"
        printf "    %-6s %-10s %-10s %-10s %-12s %s\n" \
            "$op" "$version" "$(release_field "$i" previous)" \
            "$targets" "$ocp_version" "$extra"
    done
    echo ""
}

# ── Steps ────────────────────────────────────────────────────────────────────

tag_upstream() {
    step "tag_upstream — creating upstream tags from downstream submodule commits"

    local tagged=() skipped=()

    for ((i=0; i<RELEASE_COUNT; i++)); do
        local op version
        op=$(release_field "$i" operator)
        version=$(release_field "$i" version)
        local repo="${OP_REPO[$op]}"
        local display="${OP_DISPLAY[$op]}"
        local tag="v${version}"

        local downstream_version
        downstream_version=$(release_downstream_version "$i")
        local downstream_tag="v${downstream_version}"
        if [[ "$downstream_version" != "$version" ]]; then
            info "[$op $version] Downstream tag: $downstream_tag (upstream: $tag)"
        fi

        info "[$op $version] Checking tag $tag on medik8s/$repo"

        if gh_tag_exists "medik8s/${repo}" "$tag"; then
            info "[$op $version] Tag $tag already exists on medik8s/$repo — skipping tagging"
            skipped+=("$op:$version")
            continue
        fi

        local commit
        commit=$(release_field "$i" commit)

        if [[ -n "$commit" ]]; then
            info "[$op $version] Using commit from config: $commit"
        else
            if [[ "$DRY_RUN" == true ]]; then
                echo "[dry-run] Upstream tag $tag is missing from medik8s/$repo"
                echo "[dry-run] Would clone downstream git@gitlab.cee.redhat.com:dragonfly/${repo}.git at tag $downstream_tag"
                echo "[dry-run] Would extract submodule commit for '$repo'"
                echo "[dry-run] Would clone upstream medik8s/$repo, create signed tag $tag, and push"
                tagged+=("$op:$version")
                continue
            fi

            local tmp_downstream="/tmp/${repo}-tag-$$"

            info "[$op $version] Cloning downstream at tag $downstream_tag"
            if ! git clone --depth 1 --branch "$downstream_tag" --no-checkout \
                "git@gitlab.cee.redhat.com:dragonfly/${repo}.git" "$tmp_downstream" 2>/dev/null; then
                rm -rf "$tmp_downstream"
                die "Downstream tag $downstream_tag does not exist on dragonfly/${repo}. Create it as a prerequisite or set commit in the config."
            fi

            commit=$(git -C "$tmp_downstream" ls-tree HEAD "$repo" | awk '{print $3}')
            rm -rf "$tmp_downstream"
            if [[ -z "$commit" ]]; then
                die "[$op $version] Could not extract submodule commit for '$repo' from downstream tag $downstream_tag"
            fi
            info "[$op $version] Submodule commit: $commit"
        fi

        if [[ "$DRY_RUN" == true ]]; then
            echo "[dry-run] Would create signed tag $tag on medik8s/$repo at commit $commit"
            tagged+=("$op:$version")
            continue
        fi

        info "[$op $version] Creating signed tag $tag on medik8s/$repo at commit $commit"
        local tmp_upstream="/tmp/${repo}-upstream-$$"
        if ! gh repo clone "medik8s/${repo}" "$tmp_upstream" -- --depth 1 2>/dev/null; then
            rm -rf "$tmp_upstream"
            die "[$op $version] Failed to clone upstream repo medik8s/${repo}"
        fi
        if ! git -C "$tmp_upstream" fetch --depth 1 origin "$commit" 2>/dev/null; then
            rm -rf "$tmp_upstream"
            die "[$op $version] Commit $commit does not exist on medik8s/${repo}. The downstream submodule may point to a commit that was force-pushed or rebased away."
        fi
        git -C "$tmp_upstream" tag -s "$tag" "$commit" -m "${display} ${tag}"
        git -C "$tmp_upstream" push origin "$tag"

        rm -rf "$tmp_upstream"

        tagged+=("$op:$version")
        info "[$op $version] Tag $tag created and pushed"
    done

    log "tag_upstream summary"
    if [[ ${#tagged[@]} -gt 0 ]]; then
        info "Tagged: ${tagged[*]}"
    fi
    if [[ ${#skipped[@]} -gt 0 ]]; then
        info "Skipped (already existed): ${skipped[*]}"
    fi
}

build_and_push() {
    step "build_and_push — triggering build_and_push_images workflows"

    local -a run_ids=()
    local -a run_repos=()

    for ((i=0; i<RELEASE_COUNT; i++)); do
        local op version previous
        op=$(release_field "$i" operator)
        version=$(release_field "$i" version)

        if [[ "${RELEASE_NEEDS_BUILD[$i]:-yes}" == "no" ]]; then
            info "[$op $version] Images already exist on quay.io — skipping build_and_push"
            continue
        fi

        previous=$(release_field "$i" previous)
        local repo="${OP_REPO[$op]}"
        local workflow="${OP_WORKFLOW[$op]}"
        local tag="v${version}"

        if [[ "$DRY_RUN" != true && "${RELEASE_NEEDS_BUILD[$i]}" == "partial" ]]; then
            warn "[$op $version] Partial build detected for $tag — one of operator/bundle image is missing on quay.io"
            info "A previous build_and_push may have partially failed."
            read -rp "    Proceed with build_and_push for $op $version? [y/N] " answer
            if [[ "$answer" != [yY] ]]; then
                info "[$op $version] Skipping build_and_push (user declined)"
                continue
            fi
        fi

        local -a extra_fields=()
        local srl
        srl=$(release_field "$i" skip_range_lower)
        [[ -z "$srl" ]] || extra_fields+=(-f "skip_range_lower=${srl}")

        [[ "$DRY_RUN" == true ]] || info "[$op $version] Triggering build_and_push_images on medik8s/$repo"
        run gh workflow run "$workflow" \
            --repo "medik8s/${repo}" \
            --ref "$tag" \
            -f operation=build_and_push_images \
            -f "version=${version}" \
            -f "previous_version=${previous}" \
            "${extra_fields[@]}"

        if [[ "$DRY_RUN" != true ]]; then
            capture_run_id "$op" "$repo" "$workflow" "Build"
        fi
    done

    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    if [[ ${#run_ids[@]} -gt 0 ]]; then
        wait_for_runs run_ids run_repos
    fi
}

trigger_community_workflow() {
    local op="$1" repo="$2" workflow="$3" tag="$4" version="$5" previous="$6"
    local community="$7" fork_repo="$8" branch="$9" operation="${10}"
    shift 10

    if [[ "$DRY_RUN" != true ]] && community_branch_exists "$fork_repo" "$branch"; then
        warn "[$op $version] $community branch ${branch} already exists on ${fork_repo}"
        info "A previous community workflow may have already run."
        read -rp "    Proceed and overwrite? [y/N] " answer
        if [[ "$answer" != [yY] ]]; then
            info "[$op $version] Skipping $community community workflow (user declined)"
            return 0
        fi
    fi

    [[ "$DRY_RUN" == true ]] || info "[$op $version] Triggering $operation on medik8s/$repo"
    run gh workflow run "$workflow" \
        --repo "medik8s/${repo}" \
        --ref "$tag" \
        -f "operation=${operation}" \
        -f "version=${version}" \
        -f "previous_version=${previous}" \
        "$@"

    if [[ "$DRY_RUN" != true ]]; then
        capture_run_id "$op" "$repo" "$workflow" "$community"
    fi
}

trigger_community_workflows() {
    step "trigger_community_workflows — triggering community bundle workflows"

    local -a run_ids=()
    local -a run_repos=()

    for ((i=0; i<RELEASE_COUNT; i++)); do
        local op version previous
        op=$(release_field "$i" operator)
        version=$(release_field "$i" version)
        previous=$(release_field "$i" previous)
        local repo="${OP_REPO[$op]}"
        local workflow="${OP_WORKFLOW[$op]}"
        local tag="v${version}"

        local -a extra_fields=()
        local srl
        srl=$(release_field "$i" skip_range_lower)
        [[ -z "$srl" ]] || extra_fields+=(-f "skip_range_lower=${srl}")

        if release_targets_k8s "$i"; then
            trigger_community_workflow "$op" "$repo" "$workflow" "$tag" "$version" "$previous" \
                "K8S" "medik8s/community-operators" \
                "add-${repo}-${version}-k8s" "create_k8s_release_pr" "${extra_fields[@]}"
        fi

        if release_targets_okd "$i"; then
            local ocp_version
            ocp_version=$(release_ocp_version "$i")
            trigger_community_workflow "$op" "$repo" "$workflow" "$tag" "$version" "$previous" \
                "OKD" "medik8s/community-operators-prod" \
                "add-${repo}-${version}-okd-${ocp_version}" "create_okd_release_pr" "${extra_fields[@]}" \
                -f "ocp_version=${ocp_version}"
        fi
    done

    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    if [[ ${#run_ids[@]} -gt 0 ]]; then
        wait_for_runs run_ids run_repos
    fi
}

create_community_pr() {
    local op="$1" repo="$2" version="$3" previous="$4" pr_body="$5"
    local community="$6" target_repo="$7" fork_repo="$8" branch="$9"

    if version_already_released "$target_repo" "$repo" "$version" "$previous"; then
        info "[$op $version] $community version ${version} already released in $target_repo — skipping"
        return 0
    fi

    if ! community_branch_exists "$fork_repo" "$branch"; then
        warn "[$op $version] $community branch ${branch} does not exist on ${fork_repo} — cannot create PR"
        return 0
    fi

    local existing_pr=""
    if [[ "$DRY_RUN" != true ]]; then
        existing_pr=$(gh pr view --repo "$target_repo" "medik8s:${branch}" --json url --jq '.url' 2>/dev/null || true)
    fi

    if [[ -n "$existing_pr" ]]; then
        info "[$op $version] $community PR already exists: $existing_pr"
        PR_URLS+=("$community $op: $existing_pr")
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] gh pr create --repo $target_repo --head medik8s:${branch} --base main --title operator ${repo} (${version}) --body $pr_body"
        return 0
    fi

    info "[$op $version] Creating $community PR on $target_repo (branch: $branch)"
    local pr_url
    pr_url=$(gh pr create \
        --repo "$target_repo" \
        --head "medik8s:${branch}" \
        --base main \
        --title "operator ${repo} (${version})" \
        --body "$pr_body" 2>&1) || true
    info "[$op $version] $community PR: $pr_url"
    PR_URLS+=("$community $op: $pr_url")
}

create_prs() {
    step "create_prs — creating upstream community PRs"

    for ((i=0; i<RELEASE_COUNT; i++)); do
        local op version previous
        op=$(release_field "$i" operator)
        version=$(release_field "$i" version)
        previous=$(release_field "$i" previous)
        local repo="${OP_REPO[$op]}"
        local pr_body="Add operator ${repo} (${version}), replacing ${previous}, by the [Medik8s Team](mailto:medik8s@googlegroups.com)."

        if release_targets_k8s "$i"; then
            create_community_pr "$op" "$repo" "$version" "$previous" "$pr_body" \
                "K8S" "k8s-operatorhub/community-operators" "medik8s/community-operators" \
                "add-${repo}-${version}-k8s"
        fi

        if release_targets_okd "$i"; then
            local ocp_version
            ocp_version=$(release_ocp_version "$i")
            create_community_pr "$op" "$repo" "$version" "$previous" "$pr_body" \
                "OKD" "redhat-openshift-ecosystem/community-operators-prod" "medik8s/community-operators-prod" \
                "add-${repo}-${version}-okd-${ocp_version}"
        fi
    done
}

# ── Wait for workflow runs ───────────────────────────────────────────────────

wait_for_runs() {
    local -n _ids=$1
    local -n _repos=$2

    if [[ ${#_ids[@]} -eq 0 ]]; then
        return 0
    fi

    log "Waiting for ${#_ids[@]} workflow run(s) to complete"

    local -a pending_ids=("${_ids[@]}")
    local -a pending_repos=("${_repos[@]}")

    while [[ ${#pending_ids[@]} -gt 0 ]]; do
        sleep 60
        local -a still_pending_ids=()
        local -a still_pending_repos=()

        for idx in "${!pending_ids[@]}"; do
            local run_id="${pending_ids[$idx]}"
            local repo="${pending_repos[$idx]}"

            local status conclusion
            local run_json
            run_json=$(gh run view "$run_id" --repo "$repo" --json status,conclusion 2>/dev/null || echo '{}')
            status=$(echo "$run_json" | yq e '.status // "unknown"')
            conclusion=$(echo "$run_json" | yq e '.conclusion // ""')

            if [[ "$status" == "completed" ]]; then
                if [[ "$conclusion" == "success" ]]; then
                    info "Run $run_id ($repo): completed successfully"
                else
                    warn "Run $run_id ($repo): completed with conclusion '$conclusion'"
                    info "Fetching failed logs:"
                    gh run view "$run_id" --repo "$repo" --log-failed 2>&1 | tail -50 || true
                    die "Workflow run $run_id failed. Aborting."
                fi
            else
                info "Run $run_id ($repo): status=$status — still waiting"
                still_pending_ids+=("$run_id")
                still_pending_repos+=("$repo")
            fi
        done

        pending_ids=("${still_pending_ids[@]+"${still_pending_ids[@]}"}")
        pending_repos=("${still_pending_repos[@]+"${still_pending_repos[@]}"}")
    done

    log "All workflow runs completed successfully"
}

# ── Output ───────────────────────────────────────────────────────────────────

print_summary() {
    echo ""
    log "Summary"
    echo ""
    if [[ ${#PR_URLS[@]} -gt 0 ]]; then
        printf "    %-10s %s\n" "TARGET" "PR URL"
        printf "    %-10s %s\n" "------" "------"
        for entry in "${PR_URLS[@]}"; do
            printf "    %s\n" "$entry"
        done
    else
        info "No PRs created (may have been a partial run or dry-run)."
    fi
    echo ""
}

# ── CLI ──────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <config-file.yaml>

Options:
  --dry-run       Print commands without executing them
  --step STEP     Run only one step: tag, build, community, prs
  --test          Run the test suite
  -h, --help      Show this help message

Steps:
  tag        Tag upstream repos from downstream submodule commits
  build      Trigger build_and_push_images workflows
  community  Trigger community bundle workflows and wait
  prs        Create upstream community PRs

If no --step is specified, all four steps run in sequence.
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --step)
                [[ $# -ge 2 ]] || die "--step requires an argument"
                STEP="$2"
                case "$STEP" in
                    tag|build|community|prs) ;;
                    *) die "Unknown step: $STEP (must be tag, build, community, or prs)" ;;
                esac
                shift 2
                ;;
            --test)
                exec bash "$(dirname "${BASH_SOURCE[0]}")/community-release_test.sh"
                ;;
            -h|--help)
                usage
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                if [[ -n "$CONFIG_FILE" ]]; then
                    die "Unexpected argument: $1 (config file already set to $CONFIG_FILE)"
                fi
                CONFIG_FILE="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        die "No config file specified. Run with --help for usage."
    fi
}

main() {
    parse_args "$@"

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY RUN MODE — no commands will be executed"
        echo ""
    fi

    validate_config

    case "$STEP" in
        tag)
            tag_upstream
            ;;
        build)
            build_and_push
            ;;
        community)
            trigger_community_workflows
            ;;
        prs)
            create_prs
            print_summary
            ;;
        all)
            tag_upstream
            build_and_push
            trigger_community_workflows
            create_prs
            print_summary
            ;;
    esac

    log "Done."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
