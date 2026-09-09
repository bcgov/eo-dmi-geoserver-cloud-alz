# Version Compatibility

This table records the pinned baseline. It is not a compatibility certification
for every future combination. Run the validation and integration tests after any
version change.

## Pinned Baseline

| Component | Version source | Current value |
| --- | --- | --- |
| Terraform CLI | `mise.toml` | `1.15.8` |
| Node.js local/runtime | `mise.toml`, proxy Dockerfile | `24` / Node 24 Alpine |
| Python | `mise.toml` and package requirements | `3.14.*` |
| TFLint | `mise.toml` | `0.64.0` |
| uv | `mise.toml` | `0.12.5` |
| Checkov | `mise.toml` environment | `3.3.11` |
| AzureRM TFLint ruleset | `mise.toml` environment | `0.32.0` |
| GeoServer Cloud images | `infra/stack/terraform.tfvars` | `3.0.1` |
| GeoServer ACL image | `infra/stack/terraform.tfvars` | `3.0.1` |
| RabbitMQ image | `infra/stack/terraform.tfvars` | `4.0.9-management-alpine` |
| PostgreSQL service | Terraform variable | Major version `18` |
| PostgreSQL init image | `infra/stack/main.tf` | `postgres:18.6-alpine` |
| Express | `node-oidc-proxy/package.json` | `^5.2.1` |
| `openid-client` | `node-oidc-proxy/package.json` | `^6.8.4` |
| TypeScript | `node-oidc-proxy/package.json` | `^6.0.3` |
| Pydantic | `geo-server-app-config/pyproject.toml` | `>=2.7` |
| Typer | `geo-server-app-config/pyproject.toml` | `>=0.12` |
| pytest | package and integration test manifests | `>=8` |

## Upgrade Order

1. Read release notes for the component and its image extensions.
2. Update the pinned version in the source-of-truth file.
3. Update lock files when the package manager requires it.
4. Run formatting, validation, lint, and security checks.
5. Build the affected image or import the new image into a non-production ACR.
6. Apply to `tools` or `dev`.
7. Run catalog and integration tests.
8. Review startup logs, security filters, REST, OWS, rendering, and ACL behavior.
9. Promote through `test` and `prod` with approval.

## Version-Specific Risks

- GeoServer Cloud security extensions must match the GeoServer Cloud image
  version. The current security configuration uses the built-in XML service
  because the JDBC security service was not reliable in the pinned deployment.
- The Node proxy Docker build uses Node 24. Keep `mise.toml`, the Dockerfile
  argument, and `@types/node` on the same runtime major.
- A major GeoServer catalog change may require a planned `pgconfig` reset. This
  is destructive and must use the recovery procedure.
- RabbitMQ image changes must preserve the management image behavior and the
  durable Azure File mount.

## Validation Evidence

Record the following for each upgrade:

- Terraform plan and apply result.
- Container App revision health.
- Proxy health and OIDC callback result.
- GeoServer security filter verification.
- Catalog validation and reconciliation output.
- Integration test output.
- Any changed Keycloak, ACL, or secret requirements.
