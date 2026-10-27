# .github

Special repository for organization-wide reusable Templates, Workflows, and community health files:

- [Common Agent Guide](AGENTS.md)
- [Contributing Guidelines](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security Policy](SECURITY.md)
- [Pull Request Template](.github/PULL_REQUEST_TEMPLATE.md)
- [Community Release Scripts](scripts/)
- [PR CI Label Workflow](docs/pr-check-label.md)
- [Upgrade CI Status (wiki content)](docs/upgrade-status.md)

## Publishing upgrade status to the wiki

After [openshift/release#87804](https://github.com/openshift/release/pull/87804)
merges and the scheduled jobs run, copy [docs/upgrade-status.md](docs/upgrade-status.md)
into the [wiki home page](https://github.com/medik8s/.github/wiki), below the existing
e2e status tables. The wiki is stored separately, so merging this PR does not
publish the page. Prow supplies the live badge status after the Markdown is copied.

## JavaScript development

Use Node.js 22 or newer. Install the project-local development tools using the
versions pinned in `package-lock.json`:

```bash
npm ci
```

Format the JavaScript files with Prettier:

```bash
npm run format
```

Type-check the JavaScript and its JSDoc annotations with TypeScript:

```bash
npm run typecheck
```

`tsconfig.json` enables strict checking of the `.cjs` files in `scripts/` and
`tests/`, with Node.js type definitions and no generated output. Prettier uses
the defaults declared by `.prettierrc.json`. Both commands use dependencies from
the repository's `node_modules/`.

Run the behavior tests with `npm test`, or run formatting verification, type
checking, and tests together:

```bash
npm run check
```

The [JavaScript CI workflow](.github/workflows/test-pr-check-label.yaml) runs
`npm ci` and `npm run check` using the same tools and configuration.
