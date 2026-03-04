#!/usr/bin/env bash
# Tests for community-release.sh
#
# Covers:
#   tag_upstream   — existing upstream tag, missing downstream tag, partial operator set
#   validate_config — invalid TARGET, missing OCP_VERSION, missing NHC_SKIP_RANGE_LOWER,
#                     missing PREVIOUS, no operators configured
#   create_prs     — MDR excluded for K8S-only, idempotent PR creation

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

make_mock_dir() { mktemp -d; }

# Write mock gh and curl scripts for validate_config tests.
# gh: succeeds for auth status and tag existence checks.
# curl: succeeds for quay.io tag checks.
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

# Run validate_config in a subshell with a temp config file.
# $1 = mock_dir, $2 = config file content
run_validate_config() {
    local mock_dir="$1" config_content="$2"
    local config_file
    config_file=$(mktemp)
    echo "$config_content" > "$config_file"
    (
        # shellcheck disable=SC2030,SC2031
        export PATH="${mock_dir}:${PATH}"
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/community-release.sh"
        # shellcheck disable=SC2034
        CONFIG_FILE="$config_file"
        validate_config
    )
    local rc=$?
    rm -f "$config_file"
    return $rc
}

# Run tag_upstream in a subshell with mocked binaries and operator config.
# $1 = mock_dir, remaining args = bash statements to set up operator state
run_tag_upstream_with() {
    local mock_dir="$1"; shift
    local setup="$*"
    (
        # shellcheck disable=SC2030,SC2031
        export PATH="${mock_dir}:${PATH}"
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/community-release.sh"
        # shellcheck disable=SC2034
        DRY_RUN=false
        eval "$setup"
        init_operator_metadata
        tag_upstream
    )
}

# Run create_prs in a subshell (dry-run) with operator config.
# $1 = mock_dir, remaining args = bash statements to set up state
run_create_prs_with() {
    local mock_dir="$1"; shift
    local setup="$*"
    (
        # shellcheck disable=SC2030,SC2031
        export PATH="${mock_dir}:${PATH}"
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/community-release.sh"
        eval "$setup"
        create_prs
    )
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

    # git should never be called when tag exists upstream
    cat > "${mock_dir}/git" <<'MOCK'
#!/usr/bin/env bash
echo "ERROR: git should not be called when upstream tag exists" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/git"

    local output rc=0
    output=$(run_tag_upstream_with "$mock_dir" \
        'OP_VERSION[SNR]="0.99.0"; OP_PREVIOUS[SNR]="0.98.0"' 2>&1) || rc=$?
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
    output=$(run_tag_upstream_with "$mock_dir" \
        'OP_VERSION[SNR]="0.99.0"; OP_PREVIOUS[SNR]="0.98.0"' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit, got 0"; echo "    Output: $output"; return 1; }
    assert_output_contains "downstream error" "$output" "Downstream tag v0.99.0 does not exist" || return 1
    assert_output_contains "prerequisite" "$output" "prerequisite" || return 1
}

# ── 3. Partial operators: only SNR configured, FAR not → only SNR processed ─

test_partial_operator_set() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    # Track which repos gh api was called for
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
    output=$(MOCK_LOG="$log_file" run_tag_upstream_with "$mock_dir" \
        'OP_VERSION[SNR]="0.99.0"; OP_PREVIOUS[SNR]="0.98.0"' 2>&1) || rc=$?

    local api_calls
    api_calls=$(cat "$log_file")
    rm -f "$log_file"
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }

    # Should only check SNR, not FAR/NMO/NHC/MDR
    assert_output_contains "SNR checked" "$output" '\[SNR\]' || return 1
    assert_output_not_contains "FAR not checked" "$output" '\[FAR\]' || return 1
    assert_output_not_contains "NMO not checked" "$output" '\[NMO\]' || return 1
    assert_output_not_contains "MDR not checked" "$output" '\[MDR\]' || return 1

    # Only one gh api call should have been made (for self-node-remediation)
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

    # SNR tag exists, FAR tag does not
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

    # git clone for FAR downstream fails (tag missing)
    cat > "${mock_dir}/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "clone" ]]; then exit 128; fi
echo "unexpected git call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/git"

    local output rc=0
    output=$(run_tag_upstream_with "$mock_dir" \
        'OP_VERSION[SNR]="0.99.0"; OP_PREVIOUS[SNR]="0.98.0";
         OP_VERSION[FAR]="0.7.0";  OP_PREVIOUS[FAR]="0.6.0"' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    # Should fail because FAR's downstream tag is missing
    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }

    # SNR should have been skipped (tag exists)
    assert_output_contains "SNR skipped" "$output" '\[SNR\].*already exists' || return 1
    # FAR should trigger the downstream error
    assert_output_contains "FAR downstream error" "$output" "Downstream tag v0.7.0 does not exist on dragonfly/fence-agents-remediation" || return 1
}

# ── 5. Upstream commit missing → fail with clear message ─────────────────────

test_upstream_commit_missing() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    # Tag does not exist upstream
    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/tags/* ]]; then
    exit 1
fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    # Downstream clone succeeds, ls-tree returns a commit SHA,
    # upstream clone succeeds, but fetch of the commit fails
    local call_count_file
    call_count_file=$(mktemp)
    echo "0" > "$call_count_file"

    cat > "${mock_dir}/git" <<MOCK
#!/usr/bin/env bash
case "\$1" in
    clone)
        # Both downstream and upstream clones succeed (create the dir so -C works)
        # Find the target dir (last positional arg)
        for last; do true; done
        mkdir -p "\$last"
        exit 0
        ;;
    -C)
        shift  # skip -C
        shift  # skip dir
        case "\$1" in
            ls-tree)
                # Return a fake submodule commit SHA
                echo "160000 commit abc123def456 self-node-remediation"
                exit 0
                ;;
            fetch)
                # Commit does not exist upstream
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
    output=$(run_tag_upstream_with "$mock_dir" \
        'OP_VERSION[SNR]="0.99.0"; OP_PREVIOUS[SNR]="0.98.0"' 2>&1) || rc=$?
    rm -rf "$mock_dir"
    rm -f "$call_count_file"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit, got 0"; echo "    Output: $output"; return 1; }
    assert_output_contains "commit error" "$output" "Commit abc123def456 does not exist on medik8s/self-node-remediation" || return 1
    assert_output_contains "force-push hint" "$output" "force-pushed or rebased" || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# validate_config tests
# ═══════════════════════════════════════════════════════════════════════════════

# ── 6. Invalid TARGET → fail ────────────────────────────────────────────────

test_validate_invalid_target() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'TARGET=invalid
SNR_VERSION=0.12.0
SNR_PREVIOUS=0.11.0' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "TARGET error" "$output" "TARGET must be" || return 1
}

# ── 7. Missing OCP_VERSION when TARGET=okd → fail ───────────────────────────

test_validate_missing_ocp_version() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'TARGET=okd
SNR_VERSION=0.12.0
SNR_PREVIOUS=0.11.0' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "OCP_VERSION error" "$output" "OCP_VERSION is required" || return 1
}

# ── 8. Missing NHC_SKIP_RANGE_LOWER when NHC_VERSION set → fail ─────────────

test_validate_missing_nhc_skip_range() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'TARGET=k8s
NHC_VERSION=0.11.0
NHC_PREVIOUS=0.10.0' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "NHC_SKIP_RANGE_LOWER error" "$output" "NHC_SKIP_RANGE_LOWER is required" || return 1
}

# ── 9. Missing PREVIOUS version → fail ──────────────────────────────────────

test_validate_missing_previous() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'TARGET=k8s
FAR_VERSION=0.7.0' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "PREVIOUS error" "$output" "FAR_PREVIOUS is required" || return 1
}

# ── 10. No operators configured → fail ───────────────────────────────────────

test_validate_no_operators() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'TARGET=k8s' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "no operators error" "$output" "No operators have versions set" || return 1
}

# ── 11. PREVIOUS >= VERSION → fail ───────────────────────────────────────────

test_validate_previous_higher_than_version() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'TARGET=k8s
SNR_VERSION=0.10.0
SNR_PREVIOUS=0.11.0' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "version order" "$output" "SNR_PREVIOUS (0.11.0) must be lower than SNR_VERSION (0.10.0)" || return 1
}

# ── 12. PREVIOUS == VERSION → fail ──────────────────────────────────────────

test_validate_previous_equals_version() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'TARGET=k8s
FAR_VERSION=0.7.0
FAR_PREVIOUS=0.7.0' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "version order" "$output" "FAR_PREVIOUS (0.7.0) must be lower than FAR_VERSION (0.7.0)" || return 1
}

# ── 13. Patch bump (0.10.0 → 0.10.1) → pass ────────────────────────────────

test_validate_patch_bump_ok() {
    local mock_dir
    mock_dir=$(make_mock_dir)
    write_validate_mocks "$mock_dir"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'TARGET=k8s
SNR_VERSION=0.10.1
SNR_PREVIOUS=0.10.0' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "SNR in summary" "$output" "SNR" || return 1
}

# ── 14. PREVIOUS tag missing on GitHub → fail ────────────────────────────────

test_validate_previous_tag_missing_github() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    # gh: auth OK, workflow detection OK, but tag check fails
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

    # curl: quay would succeed, but we shouldn't reach it
    cat > "${mock_dir}/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"tags":[{"name":"found"}]}'; exit 0
MOCK
    chmod +x "${mock_dir}/curl"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'TARGET=k8s
SNR_VERSION=0.12.0
SNR_PREVIOUS=0.11.0' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "github tag error" "$output" "Previous version tag v0.11.0 does not exist on medik8s/self-node-remediation" || return 1
}

# ── 15. PREVIOUS image missing on quay.io → fail ────────────────────────────

test_validate_previous_image_missing_quay() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    # gh: auth OK, workflow detection OK, tag check succeeds
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

    # curl: quay returns empty tags (image not found)
    cat > "${mock_dir}/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"tags":[]}'; exit 0
MOCK
    chmod +x "${mock_dir}/curl"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'TARGET=k8s
SNR_VERSION=0.12.0
SNR_PREVIOUS=0.11.0' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "quay image error" "$output" "quay.io/medik8s/self-node-remediation-operator:v0.11.0.*not found" || return 1
}

# ── 16. PREVIOUS bundle image missing on quay.io → fail ──────────────────────

test_validate_previous_bundle_missing_quay() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    # gh: auth OK, workflow detection OK, tag check succeeds
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

    # curl: operator image exists, but bundle image does not
    cat > "${mock_dir}/curl" <<'MOCK'
#!/usr/bin/env bash
# Check if URL contains "-bundle"
if echo "$@" | grep -q -- "-bundle"; then
    echo '{"tags":[]}'; exit 0
fi
echo '{"tags":[{"name":"found"}]}'
exit 0
MOCK
    chmod +x "${mock_dir}/curl"

    local output rc=0
    output=$(run_validate_config "$mock_dir" 'TARGET=k8s
SNR_VERSION=0.12.0
SNR_PREVIOUS=0.11.0' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -ne 0 ]] || { echo "    Expected non-zero exit"; echo "    Output: $output"; return 1; }
    assert_output_contains "bundle error" "$output" "self-node-remediation-operator-bundle:v0.11.0.*not found" || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# build_and_push tests
# ═══════════════════════════════════════════════════════════════════════════════

# ── 17. build_and_push skips operator when images already exist on quay ──────

test_build_skip_when_images_exist() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    # gh: should NOT be called for workflow run — build should be skipped
    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
echo "ERROR: gh should not be called — build should be skipped" >&2
exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    local output rc=0
    output=$(
        # shellcheck disable=SC2030,SC2031
        export PATH="${mock_dir}:${PATH}"
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/community-release.sh"
        # shellcheck disable=SC2034
        DRY_RUN=false
        # shellcheck disable=SC2034
        OP_VERSION[SNR]="0.12.0"
        # shellcheck disable=SC2034
        OP_PREVIOUS[SNR]="0.11.0"
        # shellcheck disable=SC2034
        OP_NEEDS_BUILD[SNR]=no
        build_and_push
    ) 2>&1 || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "skip message" "$output" "already exist.*skipping build_and_push" || return 1
}

# ── 18. build_and_push proceeds when OP_NEEDS_BUILD=yes ──────────────────────

test_build_proceeds_when_needed() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "${mock_dir}/gh"

    local output rc=0
    output=$(
        # shellcheck disable=SC2030,SC2031
        export PATH="${mock_dir}:${PATH}"
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/community-release.sh"
        # shellcheck disable=SC2034
        DRY_RUN=true
        # shellcheck disable=SC2034
        OP_VERSION[SNR]="0.12.0"
        # shellcheck disable=SC2034
        OP_PREVIOUS[SNR]="0.11.0"
        # shellcheck disable=SC2034
        OP_NEEDS_BUILD[SNR]=yes
        # shellcheck disable=SC2034
        OP_WORKFLOW[SNR]="release.yml"
        build_and_push
    ) 2>&1 || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "workflow triggered" "$output" "gh workflow run release.yml" || return 1
    assert_output_not_contains "no skip" "$output" "skipping build_and_push" || return 1
}

# ── 19. build_and_push partial: user declines → skip ─────────────────────────

test_build_partial_user_declines() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    # gh: should NOT be called for workflow run — user declines
    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
echo "ERROR: gh should not be called — user declined" >&2
exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    local output rc=0
    # Feed "n" to stdin for the read prompt
    output=$({
        # shellcheck disable=SC2030,SC2031
        export PATH="${mock_dir}:${PATH}"
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/community-release.sh"
        # shellcheck disable=SC2034
        DRY_RUN=false
        # shellcheck disable=SC2034
        OP_VERSION[SNR]="0.12.0"
        # shellcheck disable=SC2034
        OP_PREVIOUS[SNR]="0.11.0"
        # shellcheck disable=SC2034
        OP_NEEDS_BUILD[SNR]=partial
        # shellcheck disable=SC2034
        OP_WORKFLOW[SNR]="release.yml"
        echo "n" | build_and_push
    } 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "partial warning" "$output" "Partial build detected" || return 1
    assert_output_contains "user declined" "$output" "user declined" || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# create_prs tests
# ═══════════════════════════════════════════════════════════════════════════════

# ── 20. MDR excluded from K8S-only target ────────────────────────────────────

test_mdr_excluded_for_k8s() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
# version_already_released: not released
if [[ "$1" == "api" && "$2" == repos/*/contents/operators/* ]]; then exit 1; fi
# community_branch_exists: branch exists
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/heads/* ]]; then echo '{"ref":"found"}'; exit 0; fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    local output rc=0
    output=$(run_create_prs_with "$mock_dir" '
        # shellcheck disable=SC2034
        TARGET=k8s
        # shellcheck disable=SC2034
        DRY_RUN=true
        OP_VERSION[MDR]="0.6.0"
        OP_PREVIOUS[MDR]="0.5.0"
        OP_VERSION[SNR]="0.12.0"
        OP_PREVIOUS[SNR]="0.11.0"
    ' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }

    # SNR should get a K8S PR (dry-run shows the gh pr create command)
    assert_output_contains "SNR K8S PR" "$output" "community-operators.*self-node-remediation" || return 1

    # MDR should NOT appear at all since TARGET=k8s and MDR is OKD-only
    assert_output_not_contains "MDR excluded" "$output" "machine-deletion-remediation" || return 1
}

# ── 21. MDR included for OKD target ─────────────────────────────────────────

test_mdr_included_for_okd() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
# version_already_released: not released
if [[ "$1" == "api" && "$2" == repos/*/contents/operators/* ]]; then exit 1; fi
# community_branch_exists: branch exists
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/heads/* ]]; then echo '{"ref":"found"}'; exit 0; fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    local output rc=0
    output=$(run_create_prs_with "$mock_dir" '
        # shellcheck disable=SC2034
        TARGET=okd
        # shellcheck disable=SC2034
        OCP_VERSION=4.21
        # shellcheck disable=SC2034
        DRY_RUN=true
        OP_VERSION[MDR]="0.6.0"
        OP_PREVIOUS[MDR]="0.5.0"
    ' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }

    # MDR should get an OKD PR with -okd branch suffix
    assert_output_contains "MDR OKD PR" "$output" "community-operators-prod.*machine-deletion-remediation" || return 1
    assert_output_contains "MDR okd branch" "$output" "add-machine-deletion-remediation-0.6.0-okd" || return 1
    # MDR should NOT get a K8S PR (no k8s-operatorhub reference)
    assert_output_not_contains "MDR no K8S" "$output" "k8s-operatorhub.*machine-deletion-remediation" || return 1
}

# ── 22. TARGET=both → K8S uses -k8s suffix, OKD uses -okd suffix ─────────────

test_branch_suffixes_for_both() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
# version_already_released: not released
if [[ "$1" == "api" && "$2" == repos/*/contents/operators/* ]]; then exit 1; fi
# community_branch_exists: branch exists
if [[ "$1" == "api" && "$2" == repos/medik8s/*/git/refs/heads/* ]]; then echo '{"ref":"found"}'; exit 0; fi
echo "unexpected gh call: $*" >&2; exit 1
MOCK
    chmod +x "${mock_dir}/gh"

    local output rc=0
    output=$(run_create_prs_with "$mock_dir" '
        # shellcheck disable=SC2034
        TARGET=both
        # shellcheck disable=SC2034
        OCP_VERSION=4.21
        # shellcheck disable=SC2034
        DRY_RUN=true
        OP_VERSION[SNR]="0.12.0"
        OP_PREVIOUS[SNR]="0.11.0"
    ' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }

    # K8S PR should use -k8s suffix
    assert_output_contains "K8S branch" "$output" "add-self-node-remediation-0.12.0-k8s" || return 1
    # OKD PR should use -okd suffix
    assert_output_contains "OKD branch" "$output" "add-self-node-remediation-0.12.0-okd" || return 1
}

# ── 23. Idempotent PR creation: existing PR → skip ──────────────────────────

test_pr_already_exists() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    # gh api for version check: not released yet (404)
    # gh api for branch check: branch exists
    # gh pr view: PR exists, gh pr create: should NOT be called
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

    local output rc=0
    output=$(run_create_prs_with "$mock_dir" '
        # shellcheck disable=SC2034
        TARGET=k8s
        # shellcheck disable=SC2034
        DRY_RUN=false
        OP_VERSION[SNR]="0.12.0"
        OP_PREVIOUS[SNR]="0.11.0"
    ' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "PR exists" "$output" "already exists" || return 1
    assert_output_contains "PR URL shown" "$output" "pull/42" || return 1
}

# ── 24. Already released version → skip PR creation ──────────────────────────

test_version_already_released() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    # gh api: version directory exists, OKD CSV has matching replaces
    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then
    case "$2" in
        *manifests/*.clusterserviceversion.yaml)
            # Return base64 content (gh --jq '.content' would extract this)
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

    local output rc=0
    output=$(run_create_prs_with "$mock_dir" '
        # shellcheck disable=SC2034
        TARGET=both
        # shellcheck disable=SC2034
        OCP_VERSION=4.21
        # shellcheck disable=SC2034
        DRY_RUN=false
        OP_VERSION[SNR]="0.12.0"
        OP_PREVIOUS[SNR]="0.11.0"
    ' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "K8S skipped" "$output" "K8S version 0.12.0 already released" || return 1
    assert_output_contains "OKD skipped" "$output" "OKD version 0.12.0 already released" || return 1
    assert_output_not_contains "no PR creation" "$output" "Creating.*PR" || return 1
    assert_output_not_contains "no warning" "$output" "WARNING" || return 1
}

# ── 25. Already released but replaces mismatch → warn ────────────────────────

test_version_released_replaces_mismatch() {
    local mock_dir
    mock_dir=$(make_mock_dir)

    # gh api: version directory exists, OKD CSV has WRONG replaces
    cat > "${mock_dir}/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then
    case "$2" in
        *manifests/*.clusterserviceversion.yaml)
            # Wrong previous: v0.10.0 instead of expected v0.11.0
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

    local output rc=0
    output=$(run_create_prs_with "$mock_dir" '
        # shellcheck disable=SC2034
        TARGET=okd
        # shellcheck disable=SC2034
        OCP_VERSION=4.21
        # shellcheck disable=SC2034
        DRY_RUN=false
        OP_VERSION[SNR]="0.12.0"
        OP_PREVIOUS[SNR]="0.11.0"
    ' 2>&1) || rc=$?
    rm -rf "$mock_dir"

    [[ $rc -eq 0 ]] || { echo "    Expected exit 0, got $rc"; echo "    Output: $output"; return 1; }
    assert_output_contains "OKD skipped" "$output" "OKD version 0.12.0 already released" || return 1
    assert_output_contains "replaces warning" "$output" "does not match expected" || return 1
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

echo ""
echo "=== validate_config ==="
run_test "invalid TARGET → fail" test_validate_invalid_target
run_test "missing OCP_VERSION for OKD → fail" test_validate_missing_ocp_version
run_test "missing NHC_SKIP_RANGE_LOWER → fail" test_validate_missing_nhc_skip_range
run_test "missing PREVIOUS version → fail" test_validate_missing_previous
run_test "no operators configured → fail" test_validate_no_operators
run_test "PREVIOUS higher than VERSION → fail" test_validate_previous_higher_than_version
run_test "PREVIOUS equals VERSION → fail" test_validate_previous_equals_version
run_test "patch bump (0.10.0 → 0.10.1) → pass" test_validate_patch_bump_ok
run_test "PREVIOUS tag missing on GitHub → fail" test_validate_previous_tag_missing_github
run_test "PREVIOUS image missing on quay.io → fail" test_validate_previous_image_missing_quay
run_test "PREVIOUS bundle missing on quay.io → fail" test_validate_previous_bundle_missing_quay

echo ""
echo "=== build_and_push ==="
run_test "skip when operator+bundle images exist on quay" test_build_skip_when_images_exist
run_test "proceed when OP_NEEDS_BUILD=yes" test_build_proceeds_when_needed
run_test "partial build: user declines → skip" test_build_partial_user_declines

echo ""
echo "=== create_prs ==="
run_test "MDR excluded for K8S-only target" test_mdr_excluded_for_k8s
run_test "MDR included for OKD target" test_mdr_included_for_okd
run_test "TARGET=both → -k8s and -okd branch suffixes" test_branch_suffixes_for_both
run_test "existing PR → skip creation" test_pr_already_exists
run_test "already released version → skip PR" test_version_already_released
run_test "released with replaces mismatch → warn" test_version_released_replaces_mismatch

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
