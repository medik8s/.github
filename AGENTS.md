# AGENTS.md — Medik8s common contributor guide

This is the **official common agent guide** for the medik8s operator repositories
(FAR, MDR, NHC, NMO, SNR, SBR, …). The rules below apply to all of them on top of 
that repo's operator-specific guidance. When the two conflict, the per-repo file 
wins for that operator.

## Local development & deployment

Local development and deployment is standardized across all medik8s operators via
the shared dev environment in [`medik8s/tools`](https://github.com/medik8s/tools)
(`dev/dev.mk`). Each operator's Makefile pulls these targets in: it uses a sibling
`../tools` checkout if present, otherwise shallow-clones the repo into `.tools/` on
first `make dev-*` use. (If `make dev-*` reports "No rule to make target", the
shared include is not wired into that repo's Makefile yet — add the snippet from
[`dev/README.md`](https://github.com/medik8s/tools/blob/main/dev/README.md).)
Use these shared targets instead of per-repo equivalents wherever possible.

### Deploying operator on an OpenShift cluster via OLM:

Ensure you're logged into the cluster:

```bash
export KUBECONFIG=<path_to_kubeconfig>
```

To deploy:

```bash
make dev-olm-deploy
```

To uninstall:

```bash
make dev-olm-undeploy
```

### Deploying operator on an OpenShift cluster directly from source without OLM:

Ensure you're logged into the cluster and run:

```bash
export SKIP_KIND=true # Use an existing cluster, images are pushed to ttl.sh
make dev-setup        # Configure the cluster (namespaces, cert-manager, deps)
make dev-deploy       # Build image, install CRDs, deploy the operator
```

To redeploy the same operator after making changes:

```bash
make dev-redeploy    # Rebuild and restart pods (fast iteration)
```

To uninstall

```bash
make dev-undeploy    # Remove the operator
```

To gather debug information about deployment:

```bash
make dev-describe    # Summarize nodes, pods, CRs, leases, and events
make dev-logs        # Tail the operator controller-manager logs
```

OLM/bundle, failure-simulation, and multi-operator targets (`dev-bundle-run`, `dev-simulate-failure`, `dev-recover`, `dev-wait`, …) are also
provided — run `make dev-help` or see
[`dev/README.md`](https://github.com/medik8s/tools/blob/main/dev/README.md).

### Deploying operator to a Kind cluster

The operator can run on a [Kind](https://kind.sigs.k8s.io/) cluster, but Kind is
intended for GitHub Actions CI — not local development or testing. Use it locally
*only* to reproduce a CI failure. Note that real node reboots are disabled on Kind;
a reboot-watcher helper simulates them by restarting the node containers.

To reproduce the CI e2e run locally, exactly as GitHub Actions does it, run:

```bash
hack/local-run.sh   # Sets up the Kind cluster, starts the reboot watcher, runs e2e tests
```

Requires a Linux host with rootful containers. On Mac, a rootful Podman machine can be used.

To set up a Kind cluster and deploy the operator manually:

```bash
unset SKIP_KIND   # Kind targets require SKIP_KIND to be unset
make dev-setup    # Create Kind cluster, local image registry, webhook certs, etc.
make dev-deploy   # Build and deploy the operator from source (no OLM)
make dev-undeploy # Remove the operator from the cluster
make dev-teardown # Destroy the Kind cluster
```

## Code style

- Go, Kubebuilder v4, controller-runtime; follow standard medik8s patterns.
- Imports must be sorted (`make fix-imports`).
- No direct commits to `main`; open a PR.

## Security

- Never widen RBAC beyond the generated `config/rbac/` manifests without review.

## Keeping the docs current

If your changes affect anything documented — build commands, CRD semantics,
remediation flow, security posture, test/e2e setup — or any other existing
documentation (`README.md`, `CONTRIBUTING.md`, anything under `docs/`, inline
command or usage references), update all of it so the docs never drift from the
code.

## Commit conventions

- Brief commit messages; sign off with `-s`.
- Reference the relevant issue or PR number when applicable.
- Use WIP in the title when creating draft PRs to save CI resources.
