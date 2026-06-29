# Contributing to Medik8s

Thank you for your interest in contributing to medik8s! We welcome contributions from everyone — whether you're fixing a typo, reporting a bug, or implementing a new feature.

This guide applies to all repositories under the [medik8s](https://github.com/medik8s) GitHub organization.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Finding Something to Work On](#finding-something-to-work-on)
- [Development Workflow](#development-workflow)
- [Pull Request Process](#pull-request-process)
- [Code Style](#code-style)
- [Testing](#testing)
- [Commit Guidelines](#commit-guidelines)
- [Review and Approval](#review-and-approval)
- [Security](#security)
- [Getting Help](#getting-help)
- [License](#license)

## Code of Conduct

We have adopted the [Contributor Covenant Code of Conduct](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). Please be respectful and constructive in all interactions.

## Getting Started

### Prerequisites

- **Go** (check the specific repo's `go.mod` for the exact version required)
- **Docker** or **Podman** for container builds
- **kubectl** (or **oc** for OpenShift users)
- **operator-sdk** (check the repo's `Makefile` or documentation for the exact version)
- A Kubernetes or OpenShift cluster for E2E testing

### Repository Structure

All operator repos follow a typical layout:

```
├── api/                # CRD types, webhooks, deepcopy (v1alpha1 or v1beta1)
├── cmd/                # Entrypoint (main.go)
├── internal/           # Reconciler and internal logic
├── e2e/ or test/e2e/   # End-to-end tests
├── config/             # Kustomize manifests
├── bundle/             # OLM bundle (generated)
├── hack/               # Build scripts
├── vendor/             # Vendored Go dependencies
├── Makefile            # Build targets
├── Dockerfile          # Multi-stage container build
├── OWNERS              # Reviewers and approvers
└── .github/workflows/  # CI pipelines
```

### Fork and Clone

```bash
# Fork the repo on GitHub, then:
git clone https://github.com/<your-username>/<repo>.git
cd <repo>
git remote add upstream https://github.com/medik8s/<repo>.git
```

### Build and Test Locally

```bash
make help        # List all available Make targets
make build       # Build the operator binary
make test        # Run unit tests (uses envtest)
make manifests   # Regenerate CRDs, RBAC, webhooks
make generate    # Regenerate DeepCopy methods
make bundle      # Regenerate OLM bundle
```

## Finding Something to Work On

- Look for issues labeled **`good first issue`** or **`help wanted`** across medik8s repos
- Check individual repo issue trackers at `https://github.com/medik8s/<repo>/issues`
- Browse the [medik8s.io](https://www.medik8s.io/) website for project background
- Not looking to write code? We highly value non-code contributions! Improving documentation, expanding test coverage, and writing detailed bug reports are fantastic ways to get involved.

If you want to work on something, comment on the issue to let others know. For larger changes — especially new features or API modifications — please open an issue to discuss the approach before submitting a PR.

## Development Workflow

1. **Create a branch** from your fork's `main`:
   ```bash
   git checkout -b my-feature
   ```

2. **Make your changes** — keep commits focused and logical.

3. **Run tests locally** before pushing. In most repos, `make test` handles formatting, linting, code generation, and unit tests in one step:
   ```bash
   make test
   ```

4. **Push to your fork** and open a PR against the upstream `main` branch.

## Pull Request Process

1. **Always submit PRs from your personal fork**, not from branches on the main repository.
2. **One concern per PR** — don't mix unrelated changes.
3. **Fill in the PR description** using the provided template — explain *what* changed and *why*.
4. **All CI checks must pass** before merge. The pre-submit pipeline runs `make test` (which includes formatting, linting, code generation, and unit tests) and a container build.
5. **Respond to review feedback** promptly.
6. **Keep your branch up to date** with upstream `main` by rebasing (not merging).

## Code Style

- **Formatting and imports**: Run `make fix-imports` before committing. This ensures imports are correctly grouped (standard library, then external packages, then internal `medik8s/` packages) using the [`sort-imports`](https://github.com/slintes/sort-imports) tool.
- **Linting**: Some repos use `golangci-lint` with a `.golangci.yml` config. Check if the repo you're contributing to has one.
- **License headers**: All `.go` files must include the Apache 2.0 header from `hack/boilerplate.go.txt`.

## Testing

### Unit Tests

Written with [Ginkgo v2](https://onsi.github.io/ginkgo/) and [Gomega](https://onsi.github.io/gomega/), using `envtest` for a lightweight Kubernetes API server:

```bash
make test
```

### End-to-End Tests

Require a live Kubernetes/OpenShift cluster with the operator deployed:

```bash
make test-e2e    # or: make e2e-test (varies by repo)
```

### Writing Tests

- Place unit tests alongside the code they test (`*_test.go`)
- Place E2E tests in `e2e/` or `test/e2e/`
- Use `Describe`/`Context`/`It` blocks (Ginkgo style)
- Use `Expect()` matchers (Gomega style)
- Test failure paths, not just the happy path

## Commit Guidelines

### Developer Certificate of Origin (DCO)

We require all commits to be signed off, certifying you have the right to submit the code under the project's Apache 2.0 license. Add a `Signed-off-by` line to your commits:

```bash
git commit -s -m "Fix node health check timeout handling"
```

This adds a line like:
```
Signed-off-by: Your Name <your.email@example.com>
```

If you forget, you can amend:
```bash
git commit --amend -s
```

### Cryptographic Signing (Optional but Encouraged)

While the lightweight DCO (`Signed-off-by`) is required, cryptographic commit signing using GPG or SSH is optional but highly encouraged.

We deliberately do not enforce cryptographic signatures for community contributors to keep the barrier to entry low, and to maintain compatibility with our automated bot workflows. However, configuring it is an excellent open-source security practice. If you'd like to set it up, see the [GitHub Docs on signing commits](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits).

### Commit Messages

Write clear, concise commit messages:

```
Short summary of the change (max 70 characters)

Longer explanation if needed. Describe *why* the change was made,
not just what changed. Wrap at 72 characters.

Signed-off-by: Your Name <your.email@example.com>
```

- Use imperative mood: "Fix bug" not "Fixed bug"
- Reference related issues in the PR description (not the commit message), e.g. "Fixes #123" — this avoids unintended issue closures during cherry-picks
- Keep the subject line under 70 characters

## Review and Approval

Each repository has an `OWNERS` file listing approvers and reviewers. PRs require both `/lgtm` and `/approve` from two different OWNERS members before they can be merged.

We use [Prow](https://docs.prow.k8s.io/) to manage CI and merging. You might see maintainers leave comments like:

- `/ok-to-test` — Allows CI pipelines to run for first-time contributors. Your CI will stay pending until a maintainer comments this.
- `/lgtm` — "Looks Good To Me" — approves the code changes. A GitHub "Approve" review also counts as `/lgtm`.
- `/approve` — Approves the PR for merging.
- `/hold` — Blocks the PR from merging. Use `/hold cancel` or `/unhold` to remove.
- `/retest` — Re-runs failed CI jobs.
- `/cherry-pick <branch>` — Creates a backport PR to the specified branch.

> **Note**: Self-approval is not allowed — PRs require `/lgtm` and `/approve` from two different OWNERS members.

Reviews can sometimes take a few days. If your PR hasn't received feedback, please don't hesitate to ping the reviewers in the comments or reach out through our [Google Group](#getting-help)!

If you become a regular contributor, you may be added as a reviewer or approver.

## Security

If you discover a security vulnerability, **do not** open a public issue.

Please report vulnerabilities confidentially by contacting any of the maintainers listed in the repository's OWNERS file, or use the "Security and quality" tab on the repository to submit a private GitHub Security Advisory.

## Getting Help

If you have questions, get stuck, or just want to discuss a new idea, we'd love to hear from you!

- **Google Group**: [medik8s@googlegroups.com](https://groups.google.com/g/medik8s) — project announcements, roadmap updates, and design discussions
- **Website**: [medik8s.io](https://www.medik8s.io/) — documentation and project overview
- **GitHub Issues**: Open an issue on the relevant repo for bugs or feature requests

## License

All medik8s projects are licensed under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). By contributing, you agree that your contributions will be licensed under the same terms.
