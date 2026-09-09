# Disaster Recovery and Rollback

This document records the current recovery process and the remaining recovery
assumptions for GeoServer Cloud on Azure Container Apps.

## Recovery Scope

The stack contains these stateful or configuration-bearing areas:

| Area | State or data | Current protection |
| --- | --- | --- |
| Terraform | Azure resource references and deployment state | Azure Blob backend with Azure AD authentication and per-environment keys. |
| Key Vault | Application and deployment secrets | Private endpoint and `prevent_destroy` in the Terraform design. |
| PostgreSQL | GeoServer pgconfig catalog, PostGIS data, ACL data, and user data | Azure PostgreSQL service backups are platform-managed; restore testing is an operator responsibility. |
| RabbitMQ | Broker metadata and durable messages | Azure File share for the broker data directory. The proof-of-concept storage account is public. |
| GeoServer catalog | Workspaces, stores, layers, styles, and groups | Reproducible from catalog YAML when source data and secrets are available. |
| ACL rules | Workspace and layer permissions | Reproducible from `acl_rules.yaml`, but the current tool does not prune removed rules. |
| Container images | GeoServer, ACL, RabbitMQ, and proxy images | Pinned image tags are imported into ACR. |
| Browser sessions | Proxy JWE and GeoServer `JSESSIONID` | Ephemeral by design. Users must log in again after session-key loss. |

The project does not currently define approved RTO or RPO values. The service
owner must set those values before production approval.

## Recovery Principles

- Do not destroy Key Vault or PostgreSQL to repair an application configuration
  problem.
- Preserve Terraform state and the last known-good image tags.
- Revoke credentials before deleting their secret copies.
- Restore infrastructure first, then GeoServer security, then catalog state.
- Validate ACL denial as well as successful access after recovery.

## Terraform State Recovery

The backend state key is environment-specific:

```text
geoserver-cloud/tools.tfstate
geoserver-cloud/dev.tfstate
geoserver-cloud/test.tfstate
geoserver-cloud/prod.tfstate
```

Before any recovery operation:

```bash
./infra/scripts/tf.sh <env> init
./infra/scripts/tf.sh <env> plan
```

Do not delete or recreate the state blob as a first response to a failed apply.
Inspect the failed resource, refresh the state with an approved plan, and rerun
the saved plan or create a new plan after the failure is understood.

If a plan artifact is unavailable, create a new plan. The CI plan artifact is
intentionally short-lived because it can contain sensitive plan data.

## PostgreSQL and pgconfig Recovery

The PostgreSQL server contains:

- The GeoServer `pgconfig` catalog.
- The `geodata` PostGIS database.
- The `acl` data used by `geoserver-acl`.
- Supporting security/reference data used by the deployment.

Use Azure PostgreSQL backup and point-in-time restore features according to the
platform policy. Record the restore time and target server before changing
Terraform references.

After a restore:

1. Confirm private DNS resolves the restored server from the ACA environment.
2. Confirm the GeoServer services can connect to the restored pgconfig database.
3. Keep `reset_pgconfig_schema=false` unless a major catalog migration is being
   performed and the catalog has been backed up.
4. Run the PostGIS initialization job if the restored databases need extensions.
5. Restart services if their connection pool or catalog cache still references
   the old server.
6. Run catalog validation and reconciliation.
7. Test REST, OWS, rendering, and ACL behavior.

`reset_pgconfig_schema=true` is destructive. It drops the `pgconfig` schema and
wipes GeoServer catalog configuration before reinitialization. Use it only for a
planned major GeoServer catalog migration.

## Key Vault Recovery

If a secret is missing or invalid:

1. Identify the consuming resource and secret name.
2. Restore the secret from the approved secret-management process.
3. Restart the consuming App Service or Container App when the value is read at
   startup.
4. Re-run the health and authentication checks.

Do not print secret values in Terraform output, CI logs, or debug logs. Keep
`DEBUG_UNSAFE_HEADERS=false` during all recovery work.

## Image Rollback

Record the last known-good values of:

- `gs_cloud_version`
- `acl_version`
- `rabbitmq_image_tag`
- `proxy_image_tag`

To roll back, change the appropriate version input in a reviewed branch, run
Terraform plan, and apply the plan for the affected environment. Then run the
integration tests that cover startup, proxy, OWS, rendering, and security.

An image rollback does not roll back catalog state or database migrations. Restore
those separately if the image version requires them.

## GeoServer Security Recovery

If `configure-geoserver-security.sh` fails:

1. Check the Bastion SOCKS5 tunnel and gateway URL.
2. Check the GeoServer admin password in Key Vault.
3. Check the gateway and OWS revision health.
4. Check the filter list and security config through the GeoServer REST API.
5. Rerun the script after the cause is corrected.
6. Restart OWS services if machine-user or authkey data changed.

If OIDC admin bootstrap fails, use the built-in `admin` account from Key Vault,
then create or update the OIDC email principal in the default user/group service
and assign the required role.

## Catalog Rollback

Catalog reconciliation is idempotent but not transactional. A failed apply can
leave some resources updated.

To roll back a catalog change:

1. Revert the catalog files to the last known-good Git revision.
2. Run `geoserver-apply validate`.
3. Run the environment dry-run.
4. Apply the reverted catalog.
5. Inspect GeoServer REST state.
6. Remove ACL rules manually if the old catalog no longer contains them, because
   the current reconciler does not prune rules.

## Machine-Client Emergency Revocation

For a leaked authkey:

1. Remove or deny its ACL rules immediately.
2. Delete the corresponding GeoServer user or remove its key property.
3. Rotate or delete the Key Vault secret.
4. Restart all OWS and GWC replicas so cached user data is refreshed.
5. Confirm the old key fails against an OWS request.
6. Review access logs for use of the leaked key.

Do not remove only the Key Vault secret. The key may remain active in GeoServer.

## RabbitMQ Recovery

RabbitMQ uses an Azure File share for its data directory. If the broker is
recreated, confirm the share is mounted and contains the expected data before
starting dependent services.

If catalog events were lost:

1. Confirm RabbitMQ is healthy and remains at one warm replica.
2. Check service logs for missing queue or event-bus errors.
3. Run a catalog reconciliation to restore desired GeoServer state.
4. Check all GeoServer Cloud service replicas after reconciliation.

The current RabbitMQ storage account is a proof-of-concept public-network design.
Production recovery must include the private endpoint and private DNS hardening
before the service is approved.

## Recovery Validation

A recovery is not complete until these checks pass:

- Proxy `/healthz` returns `200`.
- Browser requests redirect to Keycloak and callback login succeeds.
- API requests without a session return `401`.
- GeoServer REST works with the intended credentials.
- Anonymous OWS requests cannot read protected layers.
- Authenticated WFS and WMS requests return expected data.
- Machine authkey access is scoped and old keys fail.
- Catalog validation and reconciliation complete without errors.
- PostgreSQL, ACL, RabbitMQ, and all Container App revisions are healthy.
