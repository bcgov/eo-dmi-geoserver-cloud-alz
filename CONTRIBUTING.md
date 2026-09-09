# Contributing

## Start With the Right Artifact

This repository uses OpenSpec for feature, refactor, and behavior changes.
Before changing infrastructure or application behavior:

1. Run `/opsx:explore` to find related work.
2. Use `/opsx:propose` for a new change.
3. Review the proposal, design, specs, and tasks.
4. Use `/opsx:apply` only after the change is approved.
5. Use `/opsx:sync` after implementation.
6. Archive completed changes with `/opsx:archive`.

Documentation-only corrections can update the relevant Markdown directly. Keep
behavioral statements tied to current Terraform, workflow, and runtime code.

## Tool Versions

Run `mise install` at the repository root. `mise.toml` is the source of truth for
Terraform, Node.js, Python, TFLint, uv, Checkov, and the Azure ruleset.

## Local Checks

Run the checks relevant to the files changed:

```bash
terraform fmt -check -recursive
terraform -chdir=infra/stack init -backend=false -input=false
terraform -chdir=infra/stack validate

cd geo-server-app-config
geoserver-apply validate --catalog-dir catalog
python -m pytest tests/ -v
```

For the TypeScript proxy:

```bash
cd node-oidc-proxy
npm ci
npm run typecheck
npm run build
```

Integration tests need a deployed environment and a Bastion SOCKS5 tunnel. See
[integration-tests/README.md](integration-tests/README.md).

## Documentation Changes

Update the closest stable document when behavior changes:

- Architecture and trust boundary: `docs/architecture.md` and
  `docs/security-and-identity.md`.
- OIDC and proxy behavior: `docs/node-oidc-proxy-contract.md`.
- Deploy and recovery: `docs/operations-guide.md`, `docs/troubleshooting.md`,
  and `docs/disaster-recovery.md`.
- Catalog schema and ACL: `docs/catalog-reference.md`.
- CI/CD: `docs/ci-cd.md`.

Use plain language. Include prerequisites, expected output, failure behavior, and
links to the source of truth. Do not document an intended feature as active until
it is implemented and tested.

## Pull Requests

- Use a Conventional Commit title, for example `docs: add recovery guide`.
- Keep infrastructure and documentation changes focused.
- Include validation evidence in the pull request description.
- Do not commit secrets, Terraform state, plan files, session cookies, or authkeys.
- Do not modify platform `*-networking` resources without explicit approval.
- Do not commit directly to `main`.

## Review Checklist

- Does the change affect an OpenSpec artifact?
- Do the docs match active Terraform and workflow values?
- Are security and failure modes documented?
- Are commands safe to rerun?
- Are links valid?
- Were the narrow checks for the changed files run?
