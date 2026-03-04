#!/usr/bin/env bash
# community-release.sh — Automate community operator releases for medik8s operators.
#
# Usage:
#   ./community-release.sh [--dry-run] [--step tag|build|community|prs] <config-file>
#
# Config file is a bash-sourceable key=value file. See release.conf.example for format.

set -euo pipefail

# ── Operator matrix ──────────────────────────────────────────────────────────
# Each operator is keyed by short name. Only OP_REPO, OP_K8S, and OP_OKD are
# declared statically. OP_DISPLAY, OP_QUAY_IMAGE, and OP_WORKFLOW are derived
# at runtime via init_operator_metadata() and detect_release_workflows().

declare -a OPERATORS=(SNR FAR NMO NHC MDR)

declare -A OP_REPO=(
    [SNR]=self-node-remediation
    [FAR]=fence-agents-remediation
    [NMO]=node-maintenance-operator
    [NHC]=node-healthcheck-operator
    [MDR]=machine-deletion-remediation
)

declare -A OP_K8S=(
    [SNR]=yes [FAR]=yes [NMO]=yes [NHC]=yes [MDR]=no
)

declare -A OP_OKD=(
    [SNR]=yes [FAR]=yes [NMO]=yes [NHC]=yes [MDR]=yes
)

# Populated by init_operator_metadata / detect_release_workflows
declare -A OP_DISPLAY=()
declare -A OP_QUAY_IMAGE=()
declare -A OP_WORKFLOW=()

# ── Globals ──────────────────────────────────────────────────────────────────

DRY_RUN=false
STEP=all          # tag, build, community, prs, or all
CONFIG_FILE=""

# Config values (populated from config file)
TARGET=""
OCP_VERSION=""

declare -A OP_VERSION=()
declare -A OP_PREVIOUS=()
declare -A OP_NEEDS_BUILD=()   # yes, no, or partial
NHC_SKIP_RANGE_LOWER=""

# Collected PR URLs for final summary
declare -a PR_URLS=()

# ── Helpers ──────────────────────────────────────────────────────────────────

log()   { echo "==> $*"; }
step()  { printf "\n==> Step: %s\n" "$*"; }
info()  { echo "    $*"; }
warn()  { echo "WARNING: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# Run a command, or print it if --dry-run (suppresses command stdout)
run() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] $*"
        return 0
    fi
    "$@" > /dev/null
}

# Check if TARGET includes k8s
target_includes_k8s() {
    [[ "$TARGET" == "k8s" || "$TARGET" == "both" ]]
}

# Check if TARGET includes okd
target_includes_okd() {
    [[ "$TARGET" == "okd" || "$TARGET" == "both" ]]
}

# Return 0 if semver $1 is strictly less than $2 (major.minor.patch)
version_lt() {
    local -a a b
    IFS=. read -ra a <<< "$1"
    IFS=. read -ra b <<< "$2"
    for i in 0 1 2; do
        if (( ${a[$i]:-0} < ${b[$i]:-0} )); then return 0; fi
        if (( ${a[$i]:-0} > ${b[$i]:-0} )); then return 1; fi
    done
    return 1  # equal → not less than
}

# Check if a tag exists on a GitHub repo (returns 0 if exists)
gh_tag_exists() {
    gh api "repos/${1}/git/refs/tags/${2}" &>/dev/null
}

# Check if an image tag exists on quay.io (returns 0 if exists)
quay_tag_exists() {
    local repo="$1" tag="$2"
    local response
    response=$(curl -sf "https://quay.io/api/v1/repository/medik8s/${repo}/tag/?specificTag=${tag}&onlyActiveTags=true" 2>/dev/null) || return 1
    local count
    count=$(echo "$response" | jq '.tags | length' 2>/dev/null) || return 1
    [[ "$count" -gt 0 ]]
}

# Check if a version is already released in a community-operators repo.
# For OKD (community-operators-prod), also verifies the CSV's replaces field
# matches the expected previous version.
# $1 = target repo, $2 = operator repo name, $3 = version, $4 = previous version
version_already_released() {
    local target_repo="$1" repo="$2" version="$3" previous="$4"

    # Check if the version directory exists
    gh api "repos/${target_repo}/contents/operators/${repo}/${version}" &>/dev/null || return 1

    # For OKD, verify the CSV replaces field matches the previous version
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

# Check if a community branch already exists on the medik8s fork.
# This indicates the community workflow already ran successfully.
# $1 = fork repo (e.g. medik8s/community-operators), $2 = branch name
community_branch_exists() {
    gh api "repos/${1}/git/refs/heads/${2}" &>/dev/null
}

# Get list of active operators (those with a version set)
active_operators() {
    for op in "${OPERATORS[@]}"; do
        if [[ -n "${OP_VERSION[$op]:-}" ]]; then
            echo "$op"
        fi
    done
}

# Derive OP_QUAY_IMAGE and OP_DISPLAY from OP_REPO for active operators.
# OP_QUAY_IMAGE: append -operator if repo name doesn't already end with it.
# OP_DISPLAY:    title-case OP_QUAY_IMAGE, replacing hyphens with spaces.
init_operator_metadata() {
    for op in $(active_operators); do
        local repo="${OP_REPO[$op]}"

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

# Detect the release workflow filename for each active operator.
# Tries release.yml then release.yaml on the GitHub repo; fails if neither exists.
detect_release_workflows() {
    for op in $(active_operators); do
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

# ── validate_config ─────────────────────────────────────────────────────────

validate_config() {
    log "Validating configuration"

    # Check required tools
    for cmd in gh git jq curl; do
        if ! command -v "$cmd" &>/dev/null; then
            die "'$cmd' is required but not found in PATH"
        fi
    done
    info "Required tools: OK"
    # Check gh auth
    if ! gh auth status &>/dev/null; then
        die "GitHub (gh) CLI is not authenticated. Run 'gh auth login' first."
    fi
    info "GitHub (gh) CLI: OK"

    # Source config file
    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "Config file not found: $CONFIG_FILE"
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    # Populate internal variables from config
    TARGET="${TARGET:-}"
    OCP_VERSION="${OCP_VERSION:-}"

    for op in "${OPERATORS[@]}"; do
        local ver_var="${op}_VERSION"
        local prev_var="${op}_PREVIOUS"
        OP_VERSION[$op]="${!ver_var:-}"
        OP_PREVIOUS[$op]="${!prev_var:-}"
    done
    NHC_SKIP_RANGE_LOWER="${NHC_SKIP_RANGE_LOWER:-}"

    # Derive display names, quay images, and detect workflows
    init_operator_metadata
    detect_release_workflows

    # Validate TARGET
    case "$TARGET" in
        k8s|okd|both) ;;
        *) die "TARGET must be 'k8s', 'okd', or 'both' (got: '$TARGET')" ;;
    esac

    # OKD requires OCP_VERSION
    if target_includes_okd && [[ -z "$OCP_VERSION" ]]; then
        die "OCP_VERSION is required when TARGET includes OKD"
    fi

    # Per-operator validation
    local active_count=0
    for op in "${OPERATORS[@]}"; do
        if [[ -z "${OP_VERSION[$op]}" ]]; then
            continue
        fi
        active_count=$((active_count + 1))

        # Require PREVIOUS
        if [[ -z "${OP_PREVIOUS[$op]}" ]]; then
            die "${op}_PREVIOUS is required when ${op}_VERSION is set"
        fi

        # PREVIOUS must be lower than VERSION
        if ! version_lt "${OP_PREVIOUS[$op]}" "${OP_VERSION[$op]}"; then
            die "${op}_PREVIOUS (${OP_PREVIOUS[$op]}) must be lower than ${op}_VERSION (${OP_VERSION[$op]})"
        fi

        # NHC requires skip_range_lower
        if [[ "$op" == "NHC" && -z "$NHC_SKIP_RANGE_LOWER" ]]; then
            die "NHC_SKIP_RANGE_LOWER is required when NHC_VERSION is set"
        fi

        # Verify PREVIOUS release exists
        local repo="${OP_REPO[$op]}"
        local quay_image="${OP_QUAY_IMAGE[$op]}"
        local prev_tag="v${OP_PREVIOUS[$op]}"
        local ver_tag="v${OP_VERSION[$op]}"

        if ! gh_tag_exists "medik8s/${repo}" "$prev_tag"; then
            die "[$op] Previous version tag $prev_tag does not exist on medik8s/${repo}. Cannot use ${OP_PREVIOUS[$op]} as previous_version."
        fi

        local bundle_image="${quay_image}-bundle"
        if ! quay_tag_exists "$quay_image" "$prev_tag" || ! quay_tag_exists "$bundle_image" "$prev_tag"; then
            die "[$op] Previous version images quay.io/medik8s/${quay_image}:${prev_tag} or quay.io/medik8s/${bundle_image}:${prev_tag} not found. The previous release may not have been fully built and pushed."
        fi

        # Check if VERSION images already exist on quay.io
        local has_operator has_bundle
        has_operator=$(quay_tag_exists "$quay_image" "$ver_tag" && echo yes || echo no)
        has_bundle=$(quay_tag_exists "$bundle_image" "$ver_tag" && echo yes || echo no)

        if [[ "$has_operator" == "yes" && "$has_bundle" == "yes" ]]; then
            info "[$op] Images quay.io/medik8s/${quay_image}:${ver_tag} and bundle already exist — build_and_push will be skipped"
            OP_NEEDS_BUILD[$op]=no
        elif [[ "$has_operator" == "yes" || "$has_bundle" == "yes" ]]; then
            warn "[$op] Partial build detected: operator=${has_operator} bundle=${has_bundle} on quay.io for ${ver_tag}"
            OP_NEEDS_BUILD[$op]=partial
        else
            OP_NEEDS_BUILD[$op]=yes
        fi
    done

    if [[ $active_count -eq 0 ]]; then
        die "No operators have versions set. Nothing to do."
    fi

    # Print summary
    log "Configuration summary"
    info "TARGET:      $TARGET"
    if target_includes_okd; then
        info "OCP_VERSION: $OCP_VERSION"
    fi
    echo ""
    printf "    %-10s %-10s %-10s %s\n" "OPERATOR" "VERSION" "PREVIOUS" "EXTRA"
    printf "    %-10s %-10s %-10s %s\n" "--------" "-------" "--------" "-----"
    for op in "${OPERATORS[@]}"; do
        if [[ -n "${OP_VERSION[$op]}" ]]; then
            local extra=""
            if [[ "$op" == "NHC" ]]; then
                extra="skip_range_lower=$NHC_SKIP_RANGE_LOWER"
            fi
            printf "    %-10s %-10s %-10s %s\n" "$op" "${OP_VERSION[$op]}" "${OP_PREVIOUS[$op]}" "$extra"
        fi
    done
    echo ""
}

# ── tag_upstream ─────────────────────────────────────────────────────────────

tag_upstream() {
    step "tag_upstream — creating upstream tags from downstream submodule commits"

    local tagged=() skipped=()

    for op in $(active_operators); do
        local repo="${OP_REPO[$op]}"
        local version="${OP_VERSION[$op]}"
        local display="${OP_DISPLAY[$op]}"
        local tag="v${version}"

        info "[$op] Checking tag $tag on medik8s/$repo"

        # Check if tag already exists on GitHub
        if gh_tag_exists "medik8s/${repo}" "$tag"; then
            info "[$op] Tag $tag already exists on medik8s/$repo — skipping tagging"
            skipped+=("$op")
            continue
        fi

        if [[ "$DRY_RUN" == true ]]; then
            echo "[dry-run] Upstream tag $tag is missing from medik8s/$repo"
            echo "[dry-run] Would clone downstream git@gitlab.cee.redhat.com:dragonfly/${repo}.git at tag $tag"
            echo "[dry-run] Would extract submodule commit for '$repo'"
            echo "[dry-run] Would clone upstream medik8s/$repo, create signed tag $tag, and push"
            tagged+=("$op")
            continue
        fi

        local tmp_downstream="/tmp/${repo}-tag-$$"
        local tmp_upstream="/tmp/${repo}-upstream-$$"

        # Clone downstream at the tag
        info "[$op] Cloning downstream at tag $tag"
        if ! git clone --depth 1 --branch "$tag" --no-checkout \
            "git@gitlab.cee.redhat.com:dragonfly/${repo}.git" "$tmp_downstream" 2>/dev/null; then
            rm -rf "$tmp_downstream"
            die "Downstream tag $tag does not exist on dragonfly/${repo}. Create it as a prerequisite before running this script."
        fi

        # Extract submodule commit SHA
        local commit
        commit=$(git -C "$tmp_downstream" ls-tree HEAD "$repo" | awk '{print $3}')
        if [[ -z "$commit" ]]; then
            rm -rf "$tmp_downstream"
            die "[$op] Could not extract submodule commit for '$repo' from downstream tag $tag"
        fi
        info "[$op] Submodule commit: $commit"

        # Clone upstream and fetch the commit
        info "[$op] Creating signed tag $tag on medik8s/$repo at commit $commit"
        if ! git clone --depth 1 "https://github.com/medik8s/${repo}.git" "$tmp_upstream" 2>/dev/null; then
            rm -rf "$tmp_downstream" "$tmp_upstream"
            die "[$op] Failed to clone upstream repo medik8s/${repo}"
        fi
        if ! git -C "$tmp_upstream" fetch --depth 1 origin "$commit" 2>/dev/null; then
            rm -rf "$tmp_downstream" "$tmp_upstream"
            die "[$op] Commit $commit does not exist on medik8s/${repo}. The downstream submodule may point to a commit that was force-pushed or rebased away."
        fi
        git -C "$tmp_upstream" tag -s "$tag" "$commit" -m "${display} ${tag}"
        git -C "$tmp_upstream" push origin "$tag"

        # Clean up
        rm -rf "$tmp_downstream" "$tmp_upstream"

        tagged+=("$op")
        info "[$op] Tag $tag created and pushed"
    done

    log "tag_upstream summary"
    if [[ ${#tagged[@]} -gt 0 ]]; then
        info "Tagged: ${tagged[*]}"
    fi
    if [[ ${#skipped[@]} -gt 0 ]]; then
        info "Skipped (already existed): ${skipped[*]}"
    fi
}

# ── build_and_push ───────────────────────────────────────────────────────────

build_and_push() {
    step "build_and_push — triggering build_and_push_images workflows"

    local -a run_ids=()
    local -a run_repos=()

    for op in $(active_operators); do
        # Skip if images already exist (determined during validate_config)
        if [[ "${OP_NEEDS_BUILD[$op]:-yes}" == "no" ]]; then
            info "[$op] Images already exist on quay.io — skipping build_and_push"
            continue
        fi

        local repo="${OP_REPO[$op]}"
        local workflow="${OP_WORKFLOW[$op]}"
        local version="${OP_VERSION[$op]}"
        local previous="${OP_PREVIOUS[$op]}"
        local tag="v${version}"

        # Partial build: one of operator/bundle exists, the other doesn't — ask user
        if [[ "$DRY_RUN" != true && "${OP_NEEDS_BUILD[$op]}" == "partial" ]]; then
            warn "[$op] Partial build detected for $tag — one of operator/bundle image is missing on quay.io"
            info "A previous build_and_push may have partially failed."
            read -rp "    Proceed with build_and_push for $op? [y/N] " answer
            if [[ "$answer" != [yY] ]]; then
                info "[$op] Skipping build_and_push (user declined)"
                continue
            fi
        fi

        local -a extra_fields=()
        if [[ "$op" == "NHC" ]]; then
            extra_fields+=(-f "skip_range_lower=${NHC_SKIP_RANGE_LOWER}")
        fi

        [[ "$DRY_RUN" == true ]] || info "[$op] Triggering build_and_push_images on medik8s/$repo"
        run gh workflow run "$workflow" \
            --repo "medik8s/${repo}" \
            --ref "$tag" \
            -f operation=build_and_push_images \
            -f "version=${version}" \
            -f "previous_version=${previous}" \
            "${extra_fields[@]}"

        if [[ "$DRY_RUN" == true ]]; then
            continue
        fi

        # Wait briefly then capture run ID
        sleep 5
        local run_id
        run_id=$(gh run list --repo "medik8s/${repo}" --workflow="$workflow" --limit 1 --json databaseId --jq '.[0].databaseId')
        if [[ -n "$run_id" ]]; then
            run_ids+=("$run_id")
            run_repos+=("medik8s/${repo}")
            info "[$op] Workflow run: https://github.com/medik8s/${repo}/actions/runs/${run_id}"
        else
            warn "[$op] Could not capture run ID"
        fi
    done

    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    if [[ ${#run_ids[@]} -gt 0 ]]; then
        wait_for_runs run_ids run_repos
    fi
}

# ── trigger_community_workflows ─────────────────────────────────────────────

trigger_community_workflows() {
    step "trigger_community_workflows — triggering community bundle workflows"

    local -a run_ids=()
    local -a run_repos=()

    for op in $(active_operators); do
        local repo="${OP_REPO[$op]}"
        local workflow="${OP_WORKFLOW[$op]}"
        local version="${OP_VERSION[$op]}"
        local previous="${OP_PREVIOUS[$op]}"
        local tag="v${version}"

        local -a extra_fields=()
        if [[ "$op" == "NHC" ]]; then
            extra_fields+=(-f "skip_range_lower=${NHC_SKIP_RANGE_LOWER}")
        fi

        # K8S workflow
        if target_includes_k8s && [[ "${OP_K8S[$op]}" == "yes" ]]; then
            local k8s_repo="k8s-operatorhub/community-operators"
            local k8s_branch="add-${repo}-${version}-k8s"
            local k8s_skip=false
            if version_already_released "$k8s_repo" "$repo" "$version" "$previous"; then
                info "[$op] K8S version ${version} already released — skipping community workflow"
                k8s_skip=true
            elif community_branch_exists "medik8s/community-operators" "$k8s_branch"; then
                warn "[$op] K8S branch ${k8s_branch} already exists on medik8s/community-operators"
                info "Re-triggering the workflow will overwrite the existing branch."
                if [[ "$DRY_RUN" != true ]]; then
                    read -rp "    Re-trigger K8S community workflow for $op? [y/N] " answer
                    if [[ "$answer" != [yY] ]]; then
                        info "[$op] Skipping K8S community workflow (user declined)"
                        k8s_skip=true
                    fi
                fi
            fi
            if [[ "$k8s_skip" == false ]]; then
                [[ "$DRY_RUN" == true ]] || info "[$op] Triggering create_k8s_release_pr on medik8s/$repo"
                run gh workflow run "$workflow" \
                    --repo "medik8s/${repo}" \
                    --ref "$tag" \
                    -f operation=create_k8s_release_pr \
                    -f "version=${version}" \
                    -f "previous_version=${previous}" \
                    "${extra_fields[@]}"

                if [[ "$DRY_RUN" != true ]]; then
                    sleep 5
                    local run_id
                    run_id=$(gh run list --repo "medik8s/${repo}" --workflow="$workflow" --limit 1 --json databaseId --jq '.[0].databaseId')
                    if [[ -n "$run_id" ]]; then
                        run_ids+=("$run_id")
                        run_repos+=("medik8s/${repo}")
                        info "[$op] K8S workflow run: https://github.com/medik8s/${repo}/actions/runs/${run_id}"
                    fi
                fi
            fi
        fi

        # OKD workflow
        if target_includes_okd && [[ "${OP_OKD[$op]}" == "yes" ]]; then
            local okd_repo="redhat-openshift-ecosystem/community-operators-prod"
            local okd_branch="add-${repo}-${version}-okd"
            local okd_skip=false
            if version_already_released "$okd_repo" "$repo" "$version" "$previous"; then
                info "[$op] OKD version ${version} already released — skipping community workflow"
                okd_skip=true
            elif community_branch_exists "medik8s/community-operators-prod" "$okd_branch"; then
                warn "[$op] OKD branch ${okd_branch} already exists on medik8s/community-operators-prod"
                info "Re-triggering the workflow will overwrite the existing branch."
                if [[ "$DRY_RUN" != true ]]; then
                    read -rp "    Re-trigger OKD community workflow for $op? [y/N] " answer
                    if [[ "$answer" != [yY] ]]; then
                        info "[$op] Skipping OKD community workflow (user declined)"
                        okd_skip=true
                    fi
                fi
            fi
            if [[ "$okd_skip" == false ]]; then
                [[ "$DRY_RUN" == true ]] || info "[$op] Triggering create_okd_release_pr on medik8s/$repo"
                run gh workflow run "$workflow" \
                    --repo "medik8s/${repo}" \
                    --ref "$tag" \
                    -f operation=create_okd_release_pr \
                    -f "version=${version}" \
                    -f "previous_version=${previous}" \
                    -f "ocp_version=${OCP_VERSION}" \
                    "${extra_fields[@]}"

                if [[ "$DRY_RUN" != true ]]; then
                    sleep 5
                    local run_id
                    run_id=$(gh run list --repo "medik8s/${repo}" --workflow="$workflow" --limit 1 --json databaseId --jq '.[0].databaseId')
                    if [[ -n "$run_id" ]]; then
                        run_ids+=("$run_id")
                        run_repos+=("medik8s/${repo}")
                        info "[$op] OKD workflow run: https://github.com/medik8s/${repo}/actions/runs/${run_id}"
                    fi
                fi
            fi
        fi
    done

    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    if [[ ${#run_ids[@]} -gt 0 ]]; then
        wait_for_runs run_ids run_repos
    fi
}

# ── create_prs ───────────────────────────────────────────────────────────────

create_prs() {
    step "create_prs — creating upstream community PRs"

    for op in $(active_operators); do
        local repo="${OP_REPO[$op]}"
        local version="${OP_VERSION[$op]}"
        local previous="${OP_PREVIOUS[$op]}"
        local pr_body="Add operator ${repo} (${version}), replacing ${previous}, by the [Medik8s Team](mailto:medik8s@googlegroups.com)."

        # K8S PR
        if target_includes_k8s && [[ "${OP_K8S[$op]}" == "yes" ]]; then
            local branch="add-${repo}-${version}-k8s"
            local target_repo="k8s-operatorhub/community-operators"

            if version_already_released "$target_repo" "$repo" "$version" "$previous"; then
                info "[$op] K8S version ${version} already released in $target_repo — skipping"
            elif ! community_branch_exists "medik8s/community-operators" "$branch"; then
                warn "[$op] K8S branch ${branch} does not exist on medik8s/community-operators — cannot create PR"
            else
                # Check if PR already exists (open)
                local existing_pr=""
                if [[ "$DRY_RUN" != true ]]; then
                    existing_pr=$(gh pr view --repo "$target_repo" "medik8s:${branch}" --json url --jq '.url' 2>/dev/null || true)
                fi

                if [[ -n "$existing_pr" ]]; then
                    info "[$op] K8S PR already exists: $existing_pr"
                    PR_URLS+=("K8S $op: $existing_pr")
                else
                    if [[ "$DRY_RUN" == true ]]; then
                        echo "[dry-run] gh pr create --repo $target_repo --head medik8s:${branch} --base main --title operator ${repo} (${version}) --body $pr_body"
                    else
                        info "[$op] Creating K8S PR on $target_repo (branch: $branch)"
                        local pr_url
                        pr_url=$(gh pr create \
                            --repo "$target_repo" \
                            --head "medik8s:${branch}" \
                            --base main \
                            --title "operator ${repo} (${version})" \
                            --body "$pr_body" 2>&1) || true
                        info "[$op] K8S PR: $pr_url"
                        PR_URLS+=("K8S $op: $pr_url")
                    fi
                fi
            fi
        fi

        # OKD PR
        if target_includes_okd && [[ "${OP_OKD[$op]}" == "yes" ]]; then
            local branch="add-${repo}-${version}-okd"
            local target_repo="redhat-openshift-ecosystem/community-operators-prod"

            if version_already_released "$target_repo" "$repo" "$version" "$previous"; then
                info "[$op] OKD version ${version} already released in $target_repo — skipping"
            elif ! community_branch_exists "medik8s/community-operators-prod" "$branch"; then
                warn "[$op] OKD branch ${branch} does not exist on medik8s/community-operators-prod — cannot create PR"
            else
                # Check if PR already exists (open)
                local existing_pr=""
                if [[ "$DRY_RUN" != true ]]; then
                    existing_pr=$(gh pr view --repo "$target_repo" "medik8s:${branch}" --json url --jq '.url' 2>/dev/null || true)
                fi

                if [[ -n "$existing_pr" ]]; then
                    info "[$op] OKD PR already exists: $existing_pr"
                    PR_URLS+=("OKD $op: $existing_pr")
                else
                    if [[ "$DRY_RUN" == true ]]; then
                        echo "[dry-run] gh pr create --repo $target_repo --head medik8s:${branch} --base main --title operator ${repo} (${version}) --body $pr_body"
                    else
                        info "[$op] Creating OKD PR on $target_repo (branch: $branch)"
                        local pr_url
                        pr_url=$(gh pr create \
                            --repo "$target_repo" \
                            --head "medik8s:${branch}" \
                            --base main \
                            --title "operator ${repo} (${version})" \
                            --body "$pr_body" 2>&1) || true
                        info "[$op] OKD PR: $pr_url"
                        PR_URLS+=("OKD $op: $pr_url")
                    fi
                fi
            fi
        fi
    done
}

# ── wait_for_runs ────────────────────────────────────────────────────────────

wait_for_runs() {
    local -n _ids=$1
    local -n _repos=$2

    if [[ ${#_ids[@]} -eq 0 ]]; then
        return 0
    fi

    log "Waiting for ${#_ids[@]} workflow run(s) to complete"

    # Build parallel arrays for pending runs
    local -a pending_ids=("${_ids[@]}")
    local -a pending_repos=("${_repos[@]}")

    while [[ ${#pending_ids[@]} -gt 0 ]]; do
        sleep 60
        local -a still_pending_ids=()
        local -a still_pending_repos=()

        for i in "${!pending_ids[@]}"; do
            local run_id="${pending_ids[$i]}"
            local repo="${pending_repos[$i]}"

            local status conclusion
            local run_json
            run_json=$(gh run view "$run_id" --repo "$repo" --json status,conclusion 2>/dev/null || echo '{}')
            status=$(echo "$run_json" | jq -r '.status // "unknown"')
            conclusion=$(echo "$run_json" | jq -r '.conclusion // ""')

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

# ── print_summary ────────────────────────────────────────────────────────────

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

# ── CLI parsing ──────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <config-file>

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

# ── Main ─────────────────────────────────────────────────────────────────────

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

# Allow sourcing for tests without running main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
