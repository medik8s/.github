---
name: community-release-pr
description: Create community release PRs for medik8s operators (K8S and/or OKD). Triggers release workflows and creates PRs against upstream community operator repos.
---

# Community Release PR Skill

## Purpose

Automate the creation of community operator release PRs for medik8s operators targeting K8S (k8s-operatorhub/community-operators) and/or OKD (redhat-openshift-ecosystem/community-operators-prod).

## Required Information

Ask the user for the following before proceeding:

1. **Community target**: `K8S`, `OKD`, or both
2. **OCP version** (required for OKD only, e.g., `4.21`)
3. **Per-operator versions** — for each operator, the `version` and `previous_version`:

| Operator | Repo | Workflow file | Notes |
|----------|------|---------------|-------|
| SNR | `medik8s/self-node-remediation` | `release.yml` | |
| FAR | `medik8s/fence-agents-remediation` | `release.yml` | |
| NMO | `medik8s/node-maintenance-operator` | `release.yaml` | |
| NHC | `medik8s/node-healthcheck-operator` | `release.yaml` | Requires `skip_range_lower` |
| MDR | `medik8s/machine-deletion-remediation` | `release.yaml` | OKD only (skip for K8S) |

## Workflow

### Step 1: Trigger release workflows

For each operator, run `gh workflow run` against the repo using the **version tag** as `--ref`:

**K8S** (`create_k8s_release_pr` operation — all repos except MDR):
```bash
gh workflow run <release.yml|release.yaml> \
  --repo medik8s/<repo> \
  --ref v<version> \
  -f operation=create_k8s_release_pr \
  -f version=<version> \
  -f previous_version=<previous_version>
```

**OKD** (`create_okd_release_pr` operation — all 5 repos):
```bash
gh workflow run <release.yml|release.yaml> \
  --repo medik8s/<repo> \
  --ref v<version> \
  -f operation=create_okd_release_pr \
  -f version=<version> \
  -f previous_version=<previous_version> \
  -f ocp_version=<ocp_version>
```

For **NHC**, always add: `-f skip_range_lower=<skip_range_lower>`

Trigger all workflows in parallel for efficiency.

### Step 2: Monitor workflows

Check status every minute until all complete:
```bash
gh run list --repo medik8s/<repo> --workflow=<release.yml|release.yaml> --limit 1
```

If any workflow fails, inspect logs with:
```bash
gh run view <run_id> --repo medik8s/<repo> --log-failed 2>&1 | grep -i -E "error|fail|fatal|##\[error"
```

### Step 3: Create upstream PRs

Once workflows succeed, branches are pushed to the medik8s forks. Create PRs against upstream:

**K8S PRs** — target: `k8s-operatorhub/community-operators`
```bash
gh pr create --repo k8s-operatorhub/community-operators \
  --head medik8s:add-<operator-name>-<version>-k8s \
  --base main \
  --title "operator <operator-name> (<version>)" \
  --body ""
```

**OKD PRs** — target: `redhat-openshift-ecosystem/community-operators-prod`
```bash
gh pr create --repo redhat-openshift-ecosystem/community-operators-prod \
  --head medik8s:add-<operator-name>-<version>-k8s \
  --base main \
  --title "operator <operator-name> (<version>)" \
  --body ""
```

Create all PRs in parallel.

### Step 4: Report results

Present a summary table with all PR links to the user.

## Prerequisites

- `gh` CLI authenticated with a token that has `repo`, `workflow`, and `read:org` scopes
- The `COMMUNITY_OPERATOR_TOKEN` org secret at `medik8s` must be valid (check at https://github.com/organizations/medik8s/settings/secrets/actions if workflows fail with "Bad credentials")
- Version tags (e.g., `v0.12.0`) must already exist on each repo

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `HTTP 403: Resource not accessible by personal access token` | CLI token lacks `workflow` scope | Use a classic PAT with `repo` + `workflow` + `read:org` scopes |
| `Bad credentials` in workflow logs | `COMMUNITY_OPERATOR_TOKEN` org secret expired | Update the secret with a fresh PAT that has `repo` and `workflow` scopes, with access to `medik8s/community-operators` and `medik8s/community-operators-prod` |
| `refusing to allow a Personal Access Token to create or update workflow without workflow scope` | `COMMUNITY_OPERATOR_TOKEN` lacks `workflow` permission | Regenerate the token with `Workflows: Read and write` permission |
