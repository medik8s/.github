#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/signed-commits.yaml"

DRY_RUN=false
ACTION="enable"
CONFIRM=false

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
    --config)
      if [[ -z "${2:-}" ]]; then
        die "--config requires a path argument"
      fi
      CONFIG="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [--disable --confirm] [--config PATH]"
      echo ""
      echo "Enable or disable required signed commits on branches defined in a YAML config."
      echo "Reads repos and branches from signed-commits.yaml (or --config PATH)."
      echo ""
      echo "Options:"
      echo "  --dry-run        Show what would be done without making changes"
      echo "  --disable        Remove the requirement instead of adding it"
      echo "  --confirm        Required with --disable to prevent accidental removal"
      echo "  --config PATH    Path to YAML config (default: signed-commits.yaml next to this script)"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ "$ACTION" == "disable" && "$DRY_RUN" != "true" && "$CONFIRM" != "true" ]]; then
  die "--disable requires --confirm (or use --dry-run to preview)"
fi

[[ -f "$CONFIG" ]] || die "Config file not found: $CONFIG"
command -v yq &>/dev/null || die "yq is required. Install from https://github.com/mikefarah/yq"
yq --version 2>&1 | grep -q "mikefarah" || die "Wrong yq variant detected. Need mikefarah/yq, not kislyuk/yq."
gh auth status &>/dev/null || die "Not authenticated with gh CLI. Run 'gh auth login' first."

ORG=$(yq '.org' "$CONFIG") || die "Failed to parse org from $CONFIG"
valid_name "$ORG" || die "Invalid org name: $ORG"

changed=0
skipped=0
failed=0

while IFS= read -r repo; do
  valid_name "$repo" || { warn "Skipping invalid repo name: $repo"; ((failed++)) || true; continue; }
  log "$repo"

  while IFS= read -r branch; do
    valid_name "$branch" || { warn "Skipping invalid branch name: $branch"; ((failed++)) || true; continue; }

    api_exit=0
    api_response=$(gh api "repos/${ORG}/${repo}/branches/${branch}/protection/required_signatures" 2>&1) || api_exit=$?
    if [[ $api_exit -eq 0 ]]; then
      current=$(echo "$api_response" | yq -p json '.enabled')
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
  done < <(yq ".repos.\"${repo}\".branches[]" "$CONFIG")
done < <(yq '.repos | keys | .[]' "$CONFIG")

log "Done: changed=${changed} skipped=${skipped} failed=${failed}"
[[ "$failed" -eq 0 ]] || exit 1
