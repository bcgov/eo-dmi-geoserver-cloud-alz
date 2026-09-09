# Operations Guide

This guide is the operator path for the GeoServer Cloud deployment. Read it with
[architecture.md](architecture.md), [security-and-identity.md](security-and-identity.md),
and [runbook.md](runbook.md). For service configuration, monitoring, and sizing,
see [geoserver-configuration.md](geoserver-configuration.md),
[monitoring.md](monitoring.md), and [cost-and-capacity.md](cost-and-capacity.md).

## Environments

| Environment | Purpose | Apply method | State key |
| --- | --- | --- | --- |
| `tools` | Pull-request Terraform plan and local shared tooling state | CI plan or `local-run.sh` | `geoserver-cloud/tools.tfstate` |
| `dev` | Development deployment | Push to `main` or manual dispatch | `geoserver-cloud/dev.tfstate` |
| `test` | Gated promotion test environment | Manual dispatch | `geoserver-cloud/test.tfstate` |
| `prod` | Gated production environment | Manual dispatch with approval | `geoserver-cloud/prod.tfstate` |

All environments use the same `infra/stack/` code. Environment values are
injected through Terraform variables and GitHub Environment Variables.

## Required Access

Before deployment, confirm:

- Azure CLI is installed and `az login` is current for local work.
- The deploy identity has the required BC Gov project security-group access.
- The spoke VNet exists and is not modified directly by this project.
- An ACA subnet with at least `/27` capacity can be created and delegated to
  `Microsoft.App/environments`.
- An App Service integration subnet with at least `/28` capacity can be created
  and delegated to `Microsoft.Web/serverFarms`.
- The private-endpoint subnet exists.
- A Bastion tunnel is available for private data-plane access when running
  locally or from a hosted runner that cannot resolve private DNS.

## Preflight Network Checks

Use the Azure portal or Azure CLI to confirm the VNet and subnet state before
running Terraform. The following values come from the target GitHub Environment
or `infra/stack/terraform.tfvars`:

```bash
az network vnet show \
  --resource-group "$TF_VAR_vnet_resource_group_name" \
  --name "$TF_VAR_vnet_name" \
  --query "{id:id,addressSpace:addressSpace.addressPrefixes}" \
  --output yaml

az network vnet subnet list \
  --resource-group "$TF_VAR_vnet_resource_group_name" \
  --vnet-name "$TF_VAR_vnet_name" \
  --output table
```

Confirm that the ACA and App Service CIDRs do not overlap existing subnets.
Confirm that the private-endpoint subnet is the platform-provided subnet. Do not
create or modify the platform `*-networking` resource group outside the module's
approved subnet operation.

## Local Deployment

Install the pinned tools first:

```bash
mise install
az login
```

Open the Bastion tunnel on port `8228`:

```bash
az network bastion tunnel \
  --name <bastion-name> \
  --resource-group <bastion-resource-group> \
  --target-resource-id <jumpbox-resource-id> \
  --resource-port 22 \
  --port 8228
```

Run the wrapper from Git Bash at the repository root:

```bash
./local-run.sh plan
./local-run.sh apply
```

`local-run.sh` uses the `tools` state backend and can run catalog bootstrap when
`CATALOG_ENV` is set:

```bash
export CATALOG_ENV=dev
./local-run.sh apply
```

For direct Terraform operations, use:

```bash
./infra/scripts/tf.sh dev init
./infra/scripts/tf.sh dev plan
./infra/scripts/tf.sh dev apply
```

Never run `terraform apply` without reviewing the plan. The saved plan is
consumed by `tf.sh apply`.

## CI/CD Deployment

The workflow sequence is documented in [ci-cd.md](ci-cd.md). In summary:

1. A pull request runs static checks and a `tools` plan.
2. A merge to `main` applies `dev`.
3. `test` and `prod` require manual dispatch.
4. The apply job runs catalog validation, a catalog dry-run, and catalog apply
   after Terraform.

## Deployment Phases

A successful Terraform apply performs these broad phases:

1. Create or update the resource group and Log Analytics workspace.
2. Create the registry and import pinned images through ACR server-side import.
3. Create Key Vault, PostgreSQL, private endpoints, and the ACA environment.
4. Publish the deployment-config files to the read-only Azure File share.
5. Start the PostGIS and GeoServer security initialization jobs.
6. Deploy RabbitMQ, ACL, gateway, and the GeoServer Cloud services.
7. Build and deploy the Node OIDC proxy image to App Service.
8. Run the GeoServer security configuration.
9. Reconcile the catalog if the workflow or local wrapper is configured to do so.

Terraform may wait for policy-managed private DNS zone groups. A timeout here
means the platform DNS link is not ready; it is not automatically a Terraform
syntax error.

## Post-Deployment Validation

Run checks in this order. Keep the environment name in every command.

### 1. Terraform outputs

```bash
terraform -chdir=infra/stack output
```

Confirm values exist for `gateway_url`, `proxy_url`, `proxy_oidc_redirect_uri`,
`acl_url`, `postgres_fqdn`, and `key_vault_uri`.

### 2. Container Apps

```bash
az containerapp list \
  --resource-group "$TF_VAR_resource_group_name" \
  --query "[].{name:name,provisioning:properties.provisioningState}" \
  --output table
```

The gateway, `webui`, `wms`, `wfs`, `wcs`, `wps`, `rest`, `gwc`, `acl`, and
RabbitMQ apps should be provisioned. Check revision health before testing data.

### 3. Proxy health

```bash
curl -fsS "$(terraform -chdir=infra/stack output -raw proxy_url)/healthz"
```

Expected response:

```json
{"status":"ok"}
```

### 4. Browser and API authentication

A browser request to the Web UI should return a login redirect:

```bash
curl -I \
  -H 'Accept: text/html' \
  "$(terraform -chdir=infra/stack output -raw proxy_url)/geoserver/cloud/web/"
```

An API request without a session should return `401`:

```bash
curl -i \
  -H 'Accept: application/json' \
  "$(terraform -chdir=infra/stack output -raw proxy_url)/geoserver/cloud/wms"
```

### 5. GeoServer REST and OWS behavior

Use the authenticated integration-test fixture or a controlled Basic credential.
Verify that:

- REST without credentials returns `401`.
- Anonymous WFS and WMS cannot read the protected wildlife layer.
- Authenticated WFS returns a FeatureCollection.
- Authenticated WMS returns an image.
- A machine authkey can read the configured OWS layer.
- A machine authkey is not accepted by `/rest` or `/web`.

### 6. Catalog reconciliation

```bash
cd geo-server-app-config
geoserver-apply validate --catalog-dir catalog
geoserver-apply run dev --catalog-dir catalog --env-dir environments \
  --stack-dir ../infra/stack --dry-run
```

Apply only after the validation and dry-run output are reviewed:

```bash
geoserver-apply run dev --catalog-dir catalog --env-dir environments \
  --stack-dir ../infra/stack
```

The operation is idempotent but not transactional. If it reports errors, inspect
the per-resource output and rerun after fixing the cause. It does not undo
resources that were successfully updated before a later error.

## Security Bootstrap Verification

The security script configures `headerAuth`, optional `authKey`, the filter
chains, the administrator principal, and machine users. Verify:

```bash
curl -u "admin:${GS_ADMIN_PASS}" \
  "${GATEWAY_URL}/geoserver/cloud/rest/security/authfilters.xml"

curl -u "admin:${GS_ADMIN_PASS}" \
  "${GATEWAY_URL}/geoserver/cloud/rest/resource/security/config.xml"
```

Check that:

- `headerAuth` has `sec-username`, `sec-roles`, and `roleSource=Header`.
- `headerAuth` is in `web`, `default`, `gwc`, and `rest`.
- `authKey` is in `default` and `gwc` only.
- The default XML user/group service is healthy.
- Machine users have their `UUID` user property when machine clients are enabled.

## Configuration Updates

- Change infrastructure values through Terraform variables and a reviewed plan.
- Change service Spring settings in `infra/deployment-config/`; Terraform
  republishes the bundle when file contents change.
- Change catalog state in `geo-server-app-config/catalog/` and reconcile it.
- Change security filters through the security script or a reviewed OpenSpec
  change. Do not edit a running GeoServer data directory manually.

## Hardening Before Production

- Set Key Vault public access to false and network ACL default action to `Deny`
  after a VNet-attached apply path is available.
- Keep `DEBUG_UNSAFE_HEADERS=false`.
- Keep `GATEWAY_TLS_INSECURE=false`.
- Enable PostgreSQL HA and choose a production SKU.
- Replace the proof-of-concept public RabbitMQ storage path with a private
  endpoint and private DNS.
- Decide whether GeoWebCache needs durable Azure Files storage.
- Define Log Analytics alerts and retention.
- Test secret rotation, restore, and machine-key revocation.

## Failure and Recovery Links

- [troubleshooting.md](troubleshooting.md)
- [disaster-recovery.md](disaster-recovery.md)
- [security-and-identity.md](security-and-identity.md)
- [catalog-reference.md](catalog-reference.md)
- [integration-tests/README.md](../integration-tests/README.md)
