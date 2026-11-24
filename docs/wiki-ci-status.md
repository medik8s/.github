# Wiki CI Status automation

Daily GitHub Action that refreshes CI status pages on the
[medik8s/.github wiki](https://github.com/medik8s/.github/wiki) from Prow job
definitions in [`openshift/release`](https://github.com/openshift/release).

## Pages

| Page | File | Behavior |
| --- | --- | --- |
| Home (Current CI Status) | `Home.md` | Only `*-daily-*` periodics with Prow `badge.svg` + history link; only the marker block is overwritten |
| Weekly CI Status | `Weekly-CI-Status.md` | Fully regenerated (same badge style) |
| All Jobs | `All-Jobs.md` | Fully regenerated; sections: PRs (general), PRs (by operator), Periodics, Other |

### Home markers

```html
<!-- AUTO-GENERATED:DAILY-START -->
... generated daily periodics ...
<!-- AUTO-GENERATED:DAILY-END -->
```

- If the markers are missing, the auto block is **prepended** to `Home.md`.
- If they exist, **only that block** is replaced; manual sections outside it are kept.

## Discovery rules

Jobs are loaded from `ci-operator/jobs/` in `openshift/release`:

1. `openshift/rhwa-system-tests/*-{periodics,presubmits}.yaml`
2. Every `medik8s/<component>/` directory that contains periodics/presubmits YAML
   (directories with only `OWNERS` are skipped)

Daily vs weekly classification uses the job **cron**:

- day-of-month `*` and day-of-week `*` → daily
- day-of-month `*` and day-of-week set → weekly
- anything else → All Jobs only (warning logged)

Pages are grouped as **version → variant**, then three tables:

1. **Operators** (default set)
2. **WAO** (always separate)
3. **Interop** (always separate)

Version is the leading `X.Y` from the ci-operator variant
(e.g. `5.0-upstream` → version `5.0`, variant heading `upstream`).

## Workflow

- Workflow: [`.github/workflows/wiki-ci-status.yaml`](../.github/workflows/wiki-ci-status.yaml)
- Script: [`scripts/wiki-ci-status.cjs`](../scripts/wiki-ci-status.cjs)
- Schedule: `05:00 UTC` daily, plus `workflow_dispatch`

### Secret

Create an organization or repository secret named **`WIKI_TOKEN`**: a PAT or
fine-grained token that can push to `medik8s/.github.wiki`. The default
`GITHUB_TOKEN` for Actions often cannot write the wiki repository.

## Local dry-run

```bash
npm ci
git clone https://github.com/medik8s/.github.wiki.git /tmp/medik8s-wiki

node scripts/wiki-ci-status.cjs \
  --release-dir ../release \
  --wiki-dir /tmp/medik8s-wiki \
  --dry-run
```

Omit `--dry-run` to write the markdown files locally (do not push unless you
intend to update the wiki).

Integration coverage against a real release checkout:

```bash
RELEASE_DIR=../release npm test
```
