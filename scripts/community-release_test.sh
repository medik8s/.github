#!/usr/bin/env bash
# Tests for community-release.sh (YAML config version)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ── Test harness ─────────────────────────────────────────────────────────────

run_test() {
    local name="$1"
    shift
    echo "--- $name"
    if "$@"; then
        echo "    PASS"
        PASS=$((PASS + 1))
    else
        echo "    FAIL"
        FAIL=$((FAIL + 1))
    fi
}

# ── Helpers ──────────────────────────────────────────────────────────────────

make_mock_dir() {
    local d
    d=$(mktemp -d)
    ln -sf "$(command -v yq)" "${d}/yq"
    echo "$d"
}

write_yaml_config() {
    local yaml_content="$1"
    local f
    f=$(mktemp --suffix=.yaml)
    echo "$yaml_content" > "$f"
    echo "$f"
}

write_validate_mocks() {
    local mock_dir="$1"
    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/tags/* ]]; then
    echo '{"ref":"found"}'; exit 0
fi
if [[ "$1" == "api" && "$2" == repos/medik8s/*/contents/.github/workflows/* ]]; then
    echo '{"name":"release.yaml"}'; exit 0
fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    cat > "${mock_dir}/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"tags":[{"name":"found"}]}'
exit 0
MOCK
    chmod +x "${mock_dir}/curl"
}

run_validate_config() {
    local mock_dir="$1" yaml_content="$2"
    local config_file
    config_file=$(write_yaml_config "$yaml_content")
    (
        # shellcheck disable=SC2030,SC2031
        export PATH="${mock_dir}:${PATH}"
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/community-release.sh"
        CONFIG_FILE="$config_file"
        validate_config
    )
    local rc=$?
    rm -f "$config_file"
    return $rc
}

run_tag_upstream_with() {
    local mock_dir="$1" yaml_content="$2"
    local config_file
    config_file=$(write_yaml_config "$yaml_content")
    (
        # shellcheck disable=SC2030,SC2031
        export PATH="${mock_dir}:${PATH}"
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/community-release.sh"
        DRY_RUN=false
        CONFIG_FILE="$config_file"
        parse_yaml_config
        init_operator_metadata
        tag_upstream
    )
    local rc=$?
    rm -f "$config_file"
    return $rc
}

run_create_prs_with() {
    local mock_dir="$1" yaml_content="$2" extra_setup="${3:-}"
    local config_file
    config_file=$(write_yaml_config "$yaml_content")
    (
        # shellcheck disable=SC2030,SC2031
        export PATH="${mock_dir}:${PATH}"
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/community-release.sh"
        CONFIG_FILE="$config_file"
        parse_yaml_config
        [[ -z "$extra_setup" ]] || eval "$extra_setup"
        create_prs
    )
    local rc=$?
    rm -f "$config_file"
    return $rc
}

# ── assert helpers ───────────────────────────────────────────────────────────

assert_output_contains() {
    local label="$1" output="$2" pattern="$3"
    if ! echo "$output" | grep -q "$pattern"; then
        echo "    $label: expected '$pattern' in output"
        echo "    Output: $output"
        return 1
    fi
}

assert_output_not_contains() {
    local label="$1" output="$2" pattern="$3"
    if echo "$output" | grep -q "$pattern"; then
        echo "    $label: did NOT expect '$pattern' in output"
        echo "    Output: $output"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# tag_upstream tests
# ═══════════════════════════════════════════════════════════════════════════════

SNR_RELEASE='releases:
  - operator: SNR
    version: "0.99.0"
    previous: "0.98.0"'

# ── 1. Upstream tag already exists → skip, no git calls ─────────────────────

test_tag_exists_upstream() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/tags/* ]]; then
    echo '{"ref":"refs/tags/v0.99.0"}'; exit 0
fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    cat > "${mock_dir}/git" <<'MOCK'
#!/usr/bin/env bash
echo "ERROR: git should not be called when upstream tag exists" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/git"

    local output rc=0
    output=$(run_tag_upstream_with "$mock_dir" "$SNR_RELEASE" 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "already exists" "$output" "already exists" || return 1
    assert_output_contains "skipped summary" "$output" "Skipped (already existed):.*SNR" || return 1
}

# ── 2. Downstream tag missing → fail with prerequisite message ──────────────

test_downstream_tag_missing() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/tags/* ]]; then
    echo '{"message":"Not Found"}' >&2; exit 1
fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    cat > "${mock_dir}/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "clone" ]]; then exit 128; fi
echo "unexpected git call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/git"

    local output rc=0
    output=$(run_tag_upstream_with "$mock_dir" "$SNR_RELEASE" 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit, got 0"; echo "    Output: $output"; return 1; }
    assert_output_contains "downstream error" "$output" "Downstream tag v0.99.0 does not exist" || return 1
    assert_output_contains "prerequisite" "$output" "prerequisite" || return 1
}

# Note on clone mocking:
# - Downstream (GitLab) clone uses: git clone ... → mocked via git mock
# - Upstream (GitHub) clone uses: gh repo clone ... → mocked via gh mock

# ── 3. Partial operators: only SNR configured → only SNR processed ──────────

test_partial_operator_set() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/tags/* ]]; then
    echo "$2" >> "${MOCK_LOG}"
    echo '{"ref":"refs/tags/v0.99.0"}'; exit 0
fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    cat > "${mock_dir}/git" <<'MOCK'
#!/usr/bin/env bash
echo "ERROR: git should not be called" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/git"

    local log_file
    log_file=$(mktemp)
    local output rc=0
    output=$(MOCK_LOG="$log_file" run_tag_upstream_with "$mock_dir" "$SNR_RELEASE" 2>&1) || rc=$?

    local api_calls
    api_calls=$(cat "$log_file")
    rm -f "$log_file"
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }

    assert_output_contains "SNR checked" "$output" '\[SNR' || return 1
    assert_output_not_contains "FAR not checked" "$output" '\[FAR' || return 1
    assert_output_not_contains "NMO not checked" "$output" '\[NMO' || return 1
    assert_output_not_contains "MDR not checked" "$output" '\[MDR' || return 1

    local call_count
    call_count=$(echo "$api_calls" | grep -c "self-node-remediation" || true)
    if [[ "$call_count" -ne 1 ]]; then
        echo "    Expected exactly 1 API call for self-node-remediation, got $call_count"
        echo "    API calls: $api_calls"
        return 1
    fi
}

# ── 4. Mixed: one tag exists upstream, another needs downstream clone ────────

test_mixed_tags_exist_and_missing() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then
    case "$2" in
        *self-node-remediation*) echo '{"ref":"found"}'; exit 0 ;;
        *fence-agents-remediation*) exit 1 ;;
    esac
fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    cat > "${mock_dir}/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "clone" ]]; then exit 128; fi
echo "unexpected git call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/git"

    local yaml='releases:
  - operator: SNR
    version: "0.99.0"
    previous: "0.98.0"
  - operator: FAR
    version: "0.7.0"
    previous: "0.6.0"'

    local output rc=0
    output=$(run_tag_upstream_with "$mock_dir" "$yaml" 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }

    assert_output_contains "SNR skipped" "$output" '\[SNR.*already exists' || return 1
    assert_output_contains "FAR downstream error" "$output" "Downstream tag v0.7.0 does not exist on dragonfly/fence-agents-remediation" || return 1
}

# ── 5. Upstream commit missing → fail with clear message ─────────────────────

test_upstream_commit_missing() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "api" && "\$2" == repos/medik8s/*/git/refs/tags/* ]]; then
    exit 1
fi
if [[ "\$1" == "repo" && "\$2" == "clone" ]]; then
    # Find last positional arg before -- as the directory
    local_dir=""
    for arg in "\$@"; do
        [[ "\$arg" == "--" ]] && break
        local_dir="\$arg"
    done
    mkdir -p "\$local_dir"
    exit 0
fi
echo "unexpected gh call: \$*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    cat > "${mock_dir}/git" <<MOCK
#!/usr/bin/env bash
case "\$1" in
    clone)
        for last; do true; done
        mkdir -p "\$last"
        exit 0
        ;;
    -C)
        shift  # skip -C
        shift  # skip dir
        case "\$1" in
            ls-tree)
                echo "160000 commit abc123def456 self-node-remediation"
                exit 0
                ;;
            fetch)
                echo "fatal: remote error: upload-pack: not our ref abc123def456" >&2
                exit 128
                ;;
        esac
        ;;
esac
echo "unexpected git call: \$*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/git"

    local output rc=0
    output=$(run_tag_upstream_with "$mock_dir" "$SNR_RELEASE" 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit, got 0"; echo "    Output: $output"; return 1; }
    assert_output_contains "commit error" "$output" "Commit abc123def456 does not exist on medik8s/self-node-remediation" || return 1
    assert_output_contains "force-push hint" "$output" "force-pushed or rebased" || return 1
}

# ── 6. Downstream version differs from upstream ─────────────────────────────

test_tag_with_downstream_version() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/tags/* ]]; then
    exit 1
fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    cat > "${mock_dir}/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "clone" ]]; then
    echo "CLONE_ARGS: $*" >> "${MOCK_LOG}"
    exit 128
fi
echo "unexpected git call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/git"

    local yaml='releases:
  - operator: NMO
    version: "0.20.0"
    previous: "0.19.0"
    downstream_version: "5.6.0"'

    local log_file
    log_file=$(mktemp)
    local output rc=0
    output=$(MOCK_LOG="$log_file" run_tag_upstream_with "$mock_dir" "$yaml" 2>&1) || rc=$?

    local clone_args
    clone_args=$(cat "$log_file" 2>/dev/null || true)
    rm -f "$log_file"
    rm -rf "$mock_dir"

    assert_output_contains "downstream tag shown" "$output" "Downstream tag: v5.6.0" || return 1
    assert_output_contains "clone used v5.6.0" "$clone_args" "v5.6.0" || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# validate_config tests
# ═══════════════════════════════════════════════════════════════════════════════

# ── 7. Invalid target → fail ────────────────────────────────────────────────

test_validate_invalid_target() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'releases:
  - operator: SNR
    version: "0.12.0"
    previous: "0.11.0"
    targets: [invalid]
    ocp_version: "4.21"' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "target error" "$output" "invalid target" || return 1
}

# ── 8. Missing ocp_version when targets includes okd → fail ────────────────

test_validate_missing_ocp_version() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'releases:
  - operator: SNR
    version: "0.12.0"
    previous: "0.11.0"
    targets: [okd]' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "ocp_version error" "$output" "ocp_version is required" || return 1
}

# ── 10. Missing previous → fail ─────────────────────────────────────────────

test_validate_missing_previous() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'releases:
  - operator: FAR
    version: "0.7.0"
    targets: [k8s]' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "previous error" "$output" "previous is required" || return 1
}

# ── 11. No releases → fail ──────────────────────────────────────────────────

test_validate_no_releases() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'releases: []' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "no releases error" "$output" "No release entries" || return 1
}

# ── 12. Previous >= version → fail ──────────────────────────────────────────

test_validate_previous_higher_than_version() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'releases:
  - operator: SNR
    version: "0.10.0"
    previous: "0.11.0"
    targets: [k8s]' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "version order" "$output" "previous (0.11.0) must be lower than version (0.10.0)" || return 1
}

# ── 13. Previous == version → fail ──────────────────────────────────────────

test_validate_previous_equals_version() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'releases:
  - operator: FAR
    version: "0.7.0"
    previous: "0.7.0"
    targets: [k8s]' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "version order" "$output" "previous (0.7.0) must be lower than version (0.7.0)" || return 1
}

# ── 14. Patch bump → pass ───────────────────────────────────────────────────

test_validate_patch_bump_ok() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'releases:
  - operator: SNR
    version: "0.10.1"
    previous: "0.10.0"
    targets: [k8s]' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "SNR in summary" "$output" "SNR" || return 1
}

# ── 15. Previous tag missing on GitHub → fail ────────────────────────────────

test_validate_previous_tag_missing_github() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
if [[ "$1" == "api" && "$2" == repos/medik8s/*/contents/.github/workflows/* ]]; then
    echo '{"name":"release.yaml"}'; exit 0
fi
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/tags/* ]]; then exit 1; fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    cat > "${mock_dir}/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"tags":[{"name":"found"}]}'; exit 0
MOCK
    chmod +x "${mock_dir}/curl"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'releases:
  - operator: SNR
    version: "0.12.0"
    previous: "0.11.0"
    targets: [k8s]' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "github tag error" "$output" "previous version tag v0.11.0 does not exist on medik8s/self-node-remediation" || return 1
}

# ── 16. Previous image missing on quay.io → fail ────────────────────────────

test_validate_previous_image_missing_quay() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
if [[ "$1" == "api" && "$2" == repos/medik8s/*/contents/.github/workflows/* ]]; then
    echo '{"name":"release.yaml"}'; exit 0
fi
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/tags/* ]]; then
    echo '{"ref":"found"}'; exit 0
fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    cat > "${mock_dir}/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"tags":[]}'; exit 0
MOCK
    chmod +x "${mock_dir}/curl"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'releases:
  - operator: SNR
    version: "0.12.0"
    previous: "0.11.0"
    targets: [k8s]' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "quay image error" "$output" "self-node-remediation-operator:v0.11.0.*not found" || return 1
}

# ── 17. Previous bundle image missing on quay.io → fail ──────────────────────

test_validate_previous_bundle_missing_quay() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then exit 0; fi
if [[ "$1" == "api" && "$2" == repos/medik8s/*/contents/.github/workflows/* ]]; then
    echo '{"name":"release.yaml"}'; exit 0
fi
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/tags/* ]]; then
    echo '{"ref":"found"}'; exit 0
fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    cat > "${mock_dir}/curl" <<'MOCK'
#!/usr/bin/env bash
if echo "$@" | grep -q -- "-bundle"; then
    echo '{"tags":[]}'; exit 0
fi
echo '{"tags":[{"name":"found"}]}'
exit 0
MOCK
    chmod +x "${mock_dir}/curl"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'releases:
  - operator: SNR
    version: "0.12.0"
    previous: "0.11.0"
    targets: [k8s]' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "bundle error" "$output" "self-node-remediation-operator-bundle:v0.11.0.*not found" || return 1
}

# ── 18. Unknown operator → fail ──────────────────────────────────────────────

test_validate_unknown_operator() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'releases:
  - operator: XYZ
    version: "1.0.0"
    previous: "0.9.0"
    targets: [k8s]' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "unknown operator" "$output" "unknown operator.*XYZ" || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# build_and_push tests
# ═══════════════════════════════════════════════════════════════════════════════

BUILD_YAML='releases:
  - operator: SNR
    version: "0.12.0"
    previous: "0.11.0"
    targets: [k8s]'

# ── 19. build_and_push skips operator when images already exist on quay ──────

test_build_skip_when_images_exist() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
echo "ERROR: gh should not be called — build should be skipped" >&2
exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    local config_file
    config_file=$(write_yaml_config "$BUILD_YAML")

    local output rc=0
    output=$(
        # shellcheck disable=SC2030,SC2031
        export PATH="${mock_dir}:${PATH}"
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/community-release.sh"
        DRY_RUN=false
        CONFIG_FILE="$config_file"
        parse_yaml_config
        RELEASE_NEEDS_BUILD[0]=no
        build_and_push
    ) 2>&1 || rc=$?
    rm -rf "$mock_dir" "$config_file"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "skip message" "$output" "already exist.*skipping build_and_push" || return 1
}

# ── 20. build_and_push proceeds when RELEASE_NEEDS_BUILD=yes ─────────────────

test_build_proceeds_when_needed() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "${mock_dir}/gh"

    local config_file
    config_file=$(write_yaml_config "$BUILD_YAML")

    local output rc=0
    output=$(
        # shellcheck disable=SC2030,SC2031
        export PATH="${mock_dir}:${PATH}"
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/community-release.sh"
        DRY_RUN=true
        CONFIG_FILE="$config_file"
        parse_yaml_config
        RELEASE_NEEDS_BUILD[0]=yes
        OP_WORKFLOW[SNR]="release.yml"
        build_and_push
    ) 2>&1 || rc=$?
    rm -rf "$mock_dir" "$config_file"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "workflow triggered" "$output" "gh workflow run release.yml" || return 1
    assert_output_not_contains "no skip" "$output" "skipping build_and_push" || return 1
}

# ── 21. build_and_push partial: user declines → skip ─────────────────────────

test_build_partial_user_declines() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
echo "ERROR: gh should not be called — user declined" >&2
exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    local config_file
    config_file=$(write_yaml_config "$BUILD_YAML")

    local output rc=0
    output=$({
        # shellcheck disable=SC2030,SC2031
        export PATH="${mock_dir}:${PATH}"
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/community-release.sh"
        DRY_RUN=false
        CONFIG_FILE="$config_file"
        parse_yaml_config
        RELEASE_NEEDS_BUILD[0]=partial
        OP_WORKFLOW[SNR]="release.yml"
        echo "n" | build_and_push
    } 2>&1) || rc=$?
    rm -rf "$mock_dir" "$config_file"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "partial warning" "$output" "Partial build detected" || return 1
    assert_output_contains "user declined" "$output" "user declined" || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# create_prs tests
# ═══════════════════════════════════════════════════════════════════════════════

PR_GH_MOCK='#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == repos/*/contents/operators/* ]]; then exit 1; fi
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/heads/* ]]; then echo '"'"'{"ref":"found"}'"'"'; exit 0; fi
echo "unexpected gh call: $*" >&2; exit 1'

# ── 22. MDR with okd-only targets excluded from K8S ──────────────────────────

test_mdr_excluded_for_k8s() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    echo "$PR_GH_MOCK" > "${mock_dir}/gh"
    chmod +x "${mock_dir}/gh"

    local yaml='releases:
  - operator: MDR
    version: "0.6.0"
    previous: "0.5.0"
    targets: [okd]
    ocp_version: "4.21"
  - operator: SNR
    version: "0.12.0"
    previous: "0.11.0"
    targets: [k8s]'

    local output rc=0
    output=$(run_create_prs_with "$mock_dir" "$yaml" "DRY_RUN=true" 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "SNR K8S PR" "$output" "community-operators.*self-node-remediation" || return 1
    assert_output_contains "MDR OKD PR" "$output" "community-operators-prod.*machine-deletion-remediation" || return 1
    assert_output_not_contains "MDR no K8S" "$output" "k8s-operatorhub.*machine-deletion-remediation" || return 1
}

# ── 23. MDR included for OKD target ──────────────────────────────────────────

test_mdr_included_for_okd() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    echo "$PR_GH_MOCK" > "${mock_dir}/gh"
    chmod +x "${mock_dir}/gh"

    local yaml='releases:
  - operator: MDR
    version: "0.6.0"
    previous: "0.5.0"
    targets: [okd]
    ocp_version: "4.21"'

    local output rc=0
    output=$(run_create_prs_with "$mock_dir" "$yaml" "DRY_RUN=true" 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "MDR OKD PR" "$output" "community-operators-prod.*machine-deletion-remediation" || return 1
    assert_output_contains "MDR okd branch" "$output" "add-machine-deletion-remediation-0.6.0-okd-4.21" || return 1
    assert_output_not_contains "MDR no K8S" "$output" "k8s-operatorhub.*machine-deletion-remediation" || return 1
}

# ── 24. Both targets → K8S uses -k8s suffix, OKD uses -okd-{ocp} suffix ─────

test_branch_suffixes_for_both() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    echo "$PR_GH_MOCK" > "${mock_dir}/gh"
    chmod +x "${mock_dir}/gh"

    local yaml='releases:
  - operator: SNR
    version: "0.12.0"
    previous: "0.11.0"
    ocp_version: "4.21"'

    local output rc=0
    output=$(run_create_prs_with "$mock_dir" "$yaml" "DRY_RUN=true" 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "K8S branch" "$output" "add-self-node-remediation-0.12.0-k8s" || return 1
    assert_output_contains "OKD branch" "$output" "add-self-node-remediation-0.12.0-okd-4.21" || return 1
}

# ── 25. Existing PR → skip creation ──────────────────────────────────────────

test_pr_already_exists() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == repos/*/contents/operators/* ]]; then exit 1; fi
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/heads/* ]]; then echo '{"ref":"found"}'; exit 0; fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    echo "https://github.com/k8s-operatorhub/community-operators/pull/42"
    exit 0
fi
if [[ "$1" == "pr" && "$2" == "create" ]]; then
    echo "ERROR: pr create should not be called when PR exists" >&2
    exit 1
fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    local yaml='releases:
  - operator: SNR
    version: "0.12.0"
    previous: "0.11.0"
    targets: [k8s]'

    local output rc=0
    output=$(run_create_prs_with "$mock_dir" "$yaml" "DRY_RUN=false" 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "PR exists" "$output" "already exists" || return 1
    assert_output_contains "PR URL shown" "$output" "pull/42" || return 1
}

# ── 26. Already released version → skip PR creation ──────────────────────────

test_version_already_released() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then
    case "$2" in
        *manifests/*.clusterserviceversion.yaml)
            printf "  replaces: self-node-remediation.v0.11.0\n  version: 0.12.0\n" | base64 -w0
            exit 0 ;;
        repos/*/contents/operators/*)
            echo '[{"name":"manifests","type":"dir"}]'; exit 0 ;;
    esac
fi
if [[ "$1" == "pr" ]]; then
    echo "ERROR: pr commands should not be called when version is already released" >&2
    exit 1
fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    local yaml='releases:
  - operator: SNR
    version: "0.12.0"
    previous: "0.11.0"
    ocp_version: "4.21"'

    local output rc=0
    output=$(run_create_prs_with "$mock_dir" "$yaml" "DRY_RUN=false" 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "K8S skipped" "$output" "K8S version 0.12.0 already released" || return 1
    assert_output_contains "OKD skipped" "$output" "OKD version 0.12.0 already released" || return 1
    assert_output_not_contains "no PR creation" "$output" "Creating.*PR" || return 1
    assert_output_not_contains "no warning" "$output" "WARNING" || return 1
}

# ── 27. Already released but replaces mismatch → warn ────────────────────────

test_version_released_replaces_mismatch() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then
    case "$2" in
        *manifests/*.clusterserviceversion.yaml)
            printf "  replaces: self-node-remediation.v0.10.0\n  version: 0.12.0\n" | base64 -w0
            exit 0 ;;
        repos/*/contents/operators/*)
            echo '[{"name":"manifests","type":"dir"}]'; exit 0 ;;
    esac
fi
if [[ "$1" == "pr" ]]; then
    echo "ERROR: pr commands should not be called" >&2; exit 1
fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    local yaml='releases:
  - operator: SNR
    version: "0.12.0"
    previous: "0.11.0"
    targets: [okd]
    ocp_version: "4.21"'

    local output rc=0
    output=$(run_create_prs_with "$mock_dir" "$yaml" "DRY_RUN=false" 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "OKD skipped" "$output" "OKD version 0.12.0 already released" || return 1
    assert_output_contains "replaces warning" "$output" "does not match expected" || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# Multi-version tests
# ═══════════════════════════════════════════════════════════════════════════════

# ── 28. Two versions of same operator → both processed ───────────────────────

test_multi_version_same_operator() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/tags/* ]]; then
    echo '{"ref":"found"}'; exit 0
fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    cat > "${mock_dir}/git" <<'MOCK'
#!/usr/bin/env bash
echo "ERROR: git should not be called" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/git"

    local yaml='releases:
  - operator: SNR
    version: "0.12.0"
    previous: "0.11.0"
  - operator: SNR
    version: "0.11.1"
    previous: "0.11.0"'

    local output rc=0
    output=$(run_tag_upstream_with "$mock_dir" "$yaml" 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "SNR 0.12.0" "$output" '\[SNR 0.12.0\]' || return 1
    assert_output_contains "SNR 0.11.1" "$output" '\[SNR 0.11.1\]' || return 1
}

# ── 29. Default targets → both k8s and okd ───────────────────────────────────

test_default_targets() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    echo "$PR_GH_MOCK" > "${mock_dir}/gh"
    chmod +x "${mock_dir}/gh"

    local yaml='releases:
  - operator: SNR
    version: "0.12.0"
    previous: "0.11.0"
    ocp_version: "4.21"'

    local output rc=0
    output=$(run_create_prs_with "$mock_dir" "$yaml" "DRY_RUN=true" 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "K8S PR" "$output" "k8s-operatorhub/community-operators" || return 1
    assert_output_contains "OKD PR" "$output" "community-operators-prod" || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# Run all tests
# ═══════════════════════════════════════════════════════════════════════════════

echo "=== tag_upstream ==="
run_test "upstream tag exists → skip" test_tag_exists_upstream
run_test "downstream tag missing → fail" test_downstream_tag_missing
run_test "partial operator set → only active processed" test_partial_operator_set
run_test "mixed: one exists, one missing → fail on missing" test_mixed_tags_exist_and_missing
run_test "upstream commit missing → fail with hint" test_upstream_commit_missing
run_test "downstream version differs → uses downstream tag" test_tag_with_downstream_version

echo ""
echo "=== validate_config ==="
run_test "invalid target → fail" test_validate_invalid_target
run_test "missing ocp_version for OKD → fail" test_validate_missing_ocp_version
run_test "missing previous → fail" test_validate_missing_previous
run_test "no releases → fail" test_validate_no_releases
run_test "previous higher than version → fail" test_validate_previous_higher_than_version
run_test "previous equals version → fail" test_validate_previous_equals_version
run_test "patch bump (0.10.0 → 0.10.1) → pass" test_validate_patch_bump_ok
run_test "previous tag missing on GitHub → fail" test_validate_previous_tag_missing_github
run_test "previous image missing on quay.io → fail" test_validate_previous_image_missing_quay
run_test "previous bundle missing on quay.io → fail" test_validate_previous_bundle_missing_quay
run_test "unknown operator → fail" test_validate_unknown_operator

echo ""
echo "=== build_and_push ==="
run_test "skip when operator+bundle images exist on quay" test_build_skip_when_images_exist
run_test "proceed when RELEASE_NEEDS_BUILD=yes" test_build_proceeds_when_needed
run_test "partial build: user declines → skip" test_build_partial_user_declines

echo ""
echo "=== create_prs ==="
run_test "MDR okd-only excluded from K8S PRs" test_mdr_excluded_for_k8s
run_test "MDR included for OKD target" test_mdr_included_for_okd
run_test "both targets → -k8s and -okd-{ocp} branch suffixes" test_branch_suffixes_for_both
run_test "existing PR → skip creation" test_pr_already_exists
run_test "already released version → skip PR" test_version_already_released
run_test "released with replaces mismatch → warn" test_version_released_replaces_mismatch

echo ""
echo "=== multi-version ==="
run_test "two versions of same operator → both processed" test_multi_version_same_operator
run_test "default targets → both k8s and okd" test_default_targets

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
