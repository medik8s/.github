#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/signed-commits.yaml"

DRY_RUN=false
ACTION="enable"

log()  { echo "==> $*"; }
info() { echo "    $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    --disable)  ACTION="disable"; shift ;;
    --config)
      if [[ -z "${2:-}" ]]; then
        die "--config requires a path argument"
      fi
      CONFIG="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [--disable] [--config PATH]"
      echo ""
      echo "Enable or disable required signed commits on branches defined in a YAML config."
      echo "Reads repos and branches from signed-commits.yaml (or --config PATH)."
      echo ""
      echo "Options:"
      echo "  --dry-run        Show what would be done without making changes"
      echo "  --disable        Remove the requirement instead of adding it"
      echo "  --config PATH    Path to YAML config (default: signed-commits.yaml next to this script)"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -f "$CONFIG" ]] || die "Config file not found: $CONFIG"
command -v yq &>/dev/null || die "yq is required. Install from https://github.com/mikefarah/yq"
gh auth status &>/dev/null || die "Not authenticated with gh CLI. Run 'gh auth login' first."

ORG=$(yq '.org' "$CONFIG")
REPOS=$(yq '.repos | keys | .[]' "$CONFIG")

changed=0
skipped=0
failed=0

for repo in $REPOS; do
  log "$repo"
  branches=$(yq ".repos.\"${repo}\".branches[]" "$CONFIG")

  for branch in $branches; do
    api_response=$(gh api "repos/${ORG}/${repo}/branches/${branch}/protection/required_signatures" 2>&1) && \
      current=$(echo "$api_response" | yq -p json '.enabled') || \
      current="no-protection"

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
      if gh api "repos/${ORG}/${repo}/branches/${branch}/protection/required_signatures" --method DELETE --silent 2>/dev/null; then
        info "$branch — disabled"
        ((changed++)) || true
      else
        warn "$repo/$branch — failed to disable"
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
      if gh api "repos/${ORG}/${repo}/branches/${branch}/protection/required_signatures" --method POST --silent 2>/dev/null; then
        info "$branch — enabled"
        ((changed++)) || true
      else
        warn "$repo/$branch — failed to enable (need admin access?)"
        ((failed++)) || true
      fi
    fi
  done
done

log "Done: changed=${changed} skipped=${skipped} failed=${failed}"
