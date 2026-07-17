# Go Version Schemas

Each YAML file defines a Go version schema tied to an OCP release. Operator
repos reference a schema by name when calling the
[`update-go-version`](../.github/workflows/update-go-version.yaml) reusable
workflow.

## Design principles

- **`go.mod` tracks the minor version only** (e.g. `go 1.25`, not `go 1.25.0`).
- **No `toolchain` directive** — patch-level updates (`1.25.x`) are handled by
  updating the CI builder image, not `go.mod`.
- **Minor version bumps** (e.g. `1.25` → `1.26`) require an explicit `go.mod`
  update, which is what this workflow automates.

## Schema format

```yaml
# go-versions/ocp-4.21.yaml
go: "1.25"                                              # Go minor version
ci-operator-image: "rhel-9-release-golang-1.25-openshift-4.21"  # CI image tag
```

## Adding a new schema

When a new OCP version requires a Go bump:

1. Create `go-versions/ocp-X.Y.yaml` with the new values
2. Each operator repo updates its caller workflow to reference the new schema
3. On the next scheduled run (or manual dispatch), the workflow creates a PR

## Usage in operator repos

```yaml
# .github/workflows/go-update.yaml
name: Go Version Update
on:
  schedule:
    - cron: '0 8 * * 1'
  workflow_dispatch:

jobs:
  update:
    uses: medik8s/.github/.github/workflows/update-go-version.yaml@main
    with:
      version-schema: ocp-4.21
```
