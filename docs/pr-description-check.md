# Check PR descriptions against the template

The `PR Description` job in the reusable
[CI workflow](../.github/workflows/ci.yaml) verifies that a pull request
description fills in the
[pull request template](../.github/PULL_REQUEST_TEMPLATE.md). It runs only on
`pull_request` events; `push` runs skip it.

The job reads the description from the event payload. It never checks out or
executes pull request code.

## What each section must contain

The check removes the template's HTML guidance comments before measuring a
section, so an untouched template reads as empty. A word is any
whitespace-separated token with at least one alphanumeric character, which
keeps bullet markers and punctuation from padding a section. A missing heading
is treated like an empty section.

| Section | Requirement | Effect when unmet |
| --- | --- | --- |
| `#### Why we need this PR` | A Jira key (`RHWA-4444`), a GitHub issue reference (`#123`, `org/repo#123`, or an issue or pull request URL), **or** at least 15 words | Fails the job |
| `#### Changes made` | Any text | Fails the job |
| `#### Which issue(s) this PR fixes` | A GitHub issue reference **or** a Jira key. No "N/A" escape hatch | Fails the job |
| `#### Test plan` | At least 15 words | Asks CodeRabbit for a draft; **does not** fail the job |

Issue references are matched anywhere in the section, so the template's
suggested `Fixes #123` form works without being required. Jira keys are matched
case insensitively (`rhwa-4444` is accepted) but only for the configured
projects, so tokens such as `CVE-2024` or `UTF-8` are not mistaken for issues.

## Test plan drafts from CodeRabbit

When the test plan is shorter than the word minimum, the job posts one comment
asking CodeRabbit to draft a plan from the diff, and tags the author to copy it
into the description after editing it to match what they actually ran. The
comment carries a hidden marker, so it is posted once per pull request rather
than on every push.

The test plan never fails the check. If the other sections are fine, the job is
green while CodeRabbit replies.

A fork's `pull_request` token is read only, so the comment cannot be posted on
most external contributions. The job reports this as a notice and stays green;
the author can ask CodeRabbit directly with `@coderabbitai draft a test plan`.

## Bypass

Apply the `skip-pr-description-check` label to skip the whole check, including
the CodeRabbit comment. There is no automatic exemption for drafts, `[WIP]`
titles, or bots.

## Adopt in another repository

The caller needs its own triggers and token permissions; importing a reusable
workflow imports neither. Use this caller workflow:

```yaml
name: CI

on:
  push:
    branches: ['**']
  pull_request:
    branches: ['**']
    types: [opened, reopened, synchronize, edited, labeled, unlabeled]

permissions:
  contents: read
  pull-requests: write

jobs:
  ci:
    uses: medik8s/.github/.github/workflows/ci.yaml@main
```

`edited` re-runs the check when an author fixes the description — without it,
the job only re-runs on a new commit. `labeled` and `unlabeled` apply the skip
label without a push. `pull-requests: write` lets the job comment; a reusable
workflow cannot request more than its caller grants, so a caller that omits it
fails to start.

For a fixed version, pin both the workflow and the script to the same merged
commit:

```yaml
jobs:
  ci:
    uses: medik8s/.github/.github/workflows/ci.yaml@<commit-sha>
    with:
      script-ref: <commit-sha>
```

An ordinary checkout in a reusable workflow would retrieve the caller
repository, so the job explicitly checks out
[scripts/pr-description-check.cjs](../scripts/pr-description-check.cjs) from
`medik8s/.github` at `script-ref` and runs it through `github-script`.

## Customize

Pass inputs on the calling job:

```yaml
jobs:
  ci:
    uses: medik8s/.github/.github/workflows/ci.yaml@main
    with:
      description-min-words: 15
      jira-projects: 'RHWA,OCPBUGS'
      description-skip-label: skip-pr-description-check
```

`jira-projects` replaces the default list. Keys are compared case
insensitively against `<KEY>-<number>`.

## Validate changes

Install the project-local development tools, then check formatting, JSDoc
types, and the script's behavior tests:

```bash
npm ci
npm run check
```

See [JavaScript development in the README](../README.md#javascript-development)
for the individual commands.
