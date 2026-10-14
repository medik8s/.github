# Label PRs when CI passes

The reusable [PR check label workflow](../.github/workflows/pr-check-label.yaml)
maintains the green `all-checks-passed` label. It evaluates **all reported CI
checks**, including GitHub Actions check runs and legacy commit statuses such as
Prow, on the current PR head and its test merge commit.

A label is added only when at least one relevant check exists and every relevant
check has completed with `success`. Pending, failed, cancelled, timed-out,
skipped, and neutral checks prevent the label. Prow's `tide` status is excluded
because it reflects approval and merge eligibility, rather than CI results. The
labeling job itself is also excluded. Historical legacy statuses are reduced to
the latest result for each context, so a successful retest can restore the label.

The workflow removes the label when checks stop passing, when a PR gets a new
commit, or when it closes. It ignores events for old commits and rechecks the
PR's head before and after adding a label. This is a summary of reported checks,
not a replacement for branch protection: checks that have not registered yet
cannot be evaluated, and simultaneous CI changes can briefly leave the label
out of date.

## Adopt in another repository

Add `.github/workflows/auto-label-pr.yaml` to the repository's default branch:

```yaml
name: Auto Label PR on CI Success

on:
  pull_request_target:
    types: [opened, reopened, synchronize, closed]
  workflow_run:
    workflows: ['**', '!Auto Label PR on CI Success']
    types: [requested, in_progress, completed]
  check_run:
    types: [created, rerequested, completed]
  check_suite:
    types: [completed]
  status: {}
  # Reconcile events that GitHub suppresses and allow manual repair.
  schedule:
    - cron: '17,47 * * * *'
  workflow_dispatch: {}

permissions:
  contents: read
  pull-requests: write
  issues: write
  checks: read
  statuses: read

jobs:
  label:
    uses: medik8s/.github/.github/workflows/pr-check-label.yaml@main
```

Keep the caller's workflow name as shown: the `workflow_run` filter excludes it
to prevent a loop. Do not add the `Update CI label` job to required checks, and
reserve that job name for this automation.

The caller needs its own triggers; importing a reusable workflow does not import
event subscriptions. `workflow_run` handles GitHub Actions, `status` handles
legacy CI, and `check_run`/`check_suite` handle external check providers.
GitHub suppresses some check events associated with Actions, so the scheduled
run reconciles all open PRs every 30 minutes; schedules can be delayed by GitHub.
`workflow_dispatch` allows a manual reconciliation. See
[GitHub's event documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows).

The workflow uses the caller repository's `GITHUB_TOKEN`; no PAT or inherited
secrets are needed. Both the caller and reusable workflow must grant
`pull-requests: write` to add or remove PR labels. `issues: write` is also granted
for repository label creation. A reusable workflow cannot increase the caller's
token permissions. It creates the label if missing. It supports fork PRs using
base-repository events and API reads. It checks out the shared script from
`medik8s/.github` and executes that trusted automation; it never executes PR code.
Merge the reusable workflow here before enabling callers elsewhere.
The workflow loads [scripts/pr-check-label.cjs](../scripts/pr-check-label.cjs)
through `github-script`. An ordinary checkout in a reusable workflow would
retrieve the caller repository, so this checkout explicitly selects
`medik8s/.github`.

For a fixed version, pin both the workflow and script to the same merged commit:

```yaml
jobs:
  label:
    uses: medik8s/.github/.github/workflows/pr-check-label.yaml@<commit-sha>
    with:
      script-ref: <commit-sha>
```

`script-ref` defaults to `main`. Use a trusted branch, tag, or SHA from the shared
repository, and keep it aligned with the workflow version when pinning.

## Customize

Pass inputs on the calling job:

```yaml
jobs:
  label:
    uses: medik8s/.github/.github/workflows/pr-check-label.yaml@main
    with:
      label-name: all-checks-passed
      ignored-checks: '["tide", "another-non-ci-context"]'
```

`ignored-checks` replaces the default list and uses exact names. Include
`tide` if it should remain excluded. The workflow always excludes its own
GitHub Actions check regardless of this input.

## Validate changes

Install the project-local development tools, then check formatting, JSDoc
types, and the script's behavior tests:

```bash
npm ci
npm run check
```

See [JavaScript development in the README](../README.md#javascript-development)
for the individual formatting, type-checking, and test commands.

After merging, verify in one repository with a fork PR: passing checks add the
label, a new commit or pending/failed rerun clears it, and a successful retest
restores it. Check both GitHub Actions and Prow where available before rolling
out to other operator repositories.
