#!/usr/bin/env bash
set -euo pipefail

ORG="medik8s"
DRY_RUN=false
ACTION="enable"
CONFIRM=false
REPOS=()
BRANCHES=()
DEFAULT_BRANCH_PATTERN='main|release-.+'

log()  { echo "==> $*"; }
info() { echo "    $(date -u +%H:%M:%SZ) $*"; }
warn() { echo "WARNING: $(date -u +%H:%M:%SZ) $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

valid_name() { [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    --disable)  ACTION="disable"; shift ;;
    --confirm)  CONFIRM=true; shift ;;
    --org)
      [[ -n "${2:-}" ]] || die "--org requires a value"
      ORG="$2"; shift 2 ;;
    --repo)
      [[ -n "${2:-}" ]] || die "--repo requires a value"
      REPOS+=("$2"); shift 2 ;;
    --branch)
      [[ -n "${2:-}" ]] || die "--branch requires a value"
      BRANCHES+=("$2"); shift 2 ;;
    --help|-h)
      cat <<'EOF'
Usage: require-signed-commits.sh [OPTIONS]

Enable or disable required signed commits on protected branches.

By default, discovers all non-archived, non-fork repos in the org and
targets branches matching: main, release-*

Options:
  --dry-run          Show what would be done without making changes
  --disable          Remove the requirement instead of adding it
  --confirm          Required with --disable to prevent accidental removal
  --org ORG          GitHub organization (default: medik8s)
  --repo REPO        Target specific repo(s) — repeatable
  --branch PATTERN   Override branch filter — repeatable, regex
                     (default: main and release-.+)

Examples:
  require-signed-commits.sh --dry-run
  require-signed-commits.sh --repo self-node-remediation --dry-run
  require-signed-commits.sh --repo nhc --repo snr --branch main --dry-run
  require-signed-commits.sh --disable --confirm
EOF
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ "$ACTION" == "disable" && "$DRY_RUN" != "true" && "$CONFIRM" != "true" ]]; then
  die "--disable requires --confirm (or use --dry-run to preview)"
fi

gh auth status &>/dev/null || die "Not authenticated with gh CLI. Run 'gh auth login' first."
valid_name "$ORG" || die "Invalid org name: $ORG"

# Build branch pattern from --branch flags or default
if [[ ${#BRANCHES[@]} -gt 0 ]]; then
  branch_pattern=$(IFS='|'; echo "${BRANCHES[*]}")
else
  branch_pattern="$DEFAULT_BRANCH_PATTERN"
fi

# Validate regex before use (grep exit 1 = no match, exit 2 = bad regex)
grep_exit=0
grep -E "^(${branch_pattern})$" /dev/null >/dev/null 2>&1 || grep_exit=$?
[[ $grep_exit -le 1 ]] || die "Invalid branch regex: ${branch_pattern}"

# Discover repos: --repo flags or all non-archived, non-fork repos in the org
if [[ ${#REPOS[@]} -eq 0 ]]; then
  log "Discovering repos in ${ORG} (non-archived, non-fork)..."
  while IFS= read -r r; do
    [[ -n "$r" ]] && REPOS+=("$r")
  done < <(gh api "orgs/${ORG}/repos" --paginate \
    --jq '.[] | select(.archived == false and .fork == false) | .name')
  [[ ${#REPOS[@]} -gt 0 ]] || die "No repos found in org ${ORG}"
  log "Found ${#REPOS[@]} repos"
fi

changed=0
skipped=0
failed=0

for repo in "${REPOS[@]}"; do
  valid_name "$repo" || { warn "Skipping invalid repo name: $repo"; ((failed++)) || true; continue; }
  log "$repo"

  branches_exit=0
  branches_response=$(gh api "repos/${ORG}/${repo}/branches" --paginate --jq '.[].name' 2>&1) || branches_exit=$?
  if [[ $branches_exit -ne 0 ]]; then
    warn "Failed to list branches for ${ORG}/${repo}: ${branches_response}"
    ((failed++)) || true
    continue
  fi

  matched_branches=()
  while IFS= read -r b; do
    [[ -n "$b" ]] && matched_branches+=("$b")
  done < <(printf '%s\n' "$branches_response" \
    | grep -E "^(${branch_pattern})$" || true)

  if [[ ${#matched_branches[@]} -eq 0 ]]; then
    info "(no branches matching: ${branch_pattern})"
    continue
  fi

  for branch in "${matched_branches[@]}"; do
    valid_name "$branch" || { warn "Skipping invalid branch name: $branch"; ((failed++)) || true; continue; }

    api_exit=0
    api_response=$(gh api "repos/${ORG}/${repo}/branches/${branch}/protection/required_signatures" 2>&1) || api_exit=$?
    if [[ $api_exit -eq 0 ]]; then
      current=$(echo "$api_response" | grep -o '"enabled":\s*[a-z]*' | grep -o 'true\|false' || echo "unknown")
    elif echo "$api_response" | grep -q "Branch not protected\|Not Found"; then
      current="no-protection"
    else
      warn "$branch — API error: $api_response"
      ((failed++)) || true
      continue
    fi

    if [[ "$ACTION" == "disable" ]]; then
      if [[ "$current" == "false" || "$current" == "no-protection" ]]; then
        info "$branch — already disabled"
        ((skipped++)) || true
        continue
      fi
      if [[ "$DRY_RUN" == "true" ]]; then
        info "[dry-run] $branch — would DISABLE signed commits"
        continue
      fi
      if api_err=$(gh api "repos/${ORG}/${repo}/branches/${branch}/protection/required_signatures" --method DELETE 2>&1); then
        info "$branch — disabled"
        ((changed++)) || true
      else
        warn "$repo/$branch — failed to disable: $api_err"
        ((failed++)) || true
      fi
    else
      if [[ "$current" == "true" ]]; then
        info "$branch — already enabled"
        ((skipped++)) || true
        continue
      fi
      if [[ "$current" == "no-protection" ]]; then
        warn "$branch — no branch protection rule yet (waiting for branchprotector?)"
        ((skipped++)) || true
        continue
      fi
      if [[ "$DRY_RUN" == "true" ]]; then
        info "[dry-run] $branch — would ENABLE signed commits"
        continue
      fi
      if api_err=$(gh api "repos/${ORG}/${repo}/branches/${branch}/protection/required_signatures" --method POST 2>&1); then
        info "$branch — enabled"
        ((changed++)) || true
      else
        warn "$repo/$branch — failed to enable: $api_err"
        ((failed++)) || true
      fi
    fi
  done
done

log "Done: changed=${changed} skipped=${skipped} failed=${failed}"
[[ "$failed" -eq 0 ]] || exit 1
