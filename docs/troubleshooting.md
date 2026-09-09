# Troubleshooting Guide

Use this guide after checking the deployment status and the relevant workflow
logs. Do not print secrets while troubleshooting.

## Quick Checks

```bash
az account show
terraform -chdir=infra/stack output
az containerapp list --resource-group "$TF_VAR_resource_group_name" --output table
```

For local private-network operations, confirm that the Bastion SOCKS5 tunnel is
open on port `8228`.

## Common Symptoms

| Symptom | Likely cause | First action |
| --- | --- | --- |
| `SOCKS5 proxy not reachable` | Bastion tunnel is closed or uses another port. | Open the tunnel and set `SOCKS5_PORT`. |
| Terraform cannot read state | Wrong backend variables, Azure login, or state RBAC. | Run `tf.sh <env> init` and verify `TFSTATE_*`. |
| Private DNS wait times out | Platform private DNS zone group is not ready. | Check private endpoint and DNS zone links; wait or contact the platform team. |
| ACR image pull fails | ACR secret, Key Vault access, or image import problem. | Check ACR image tag, Key Vault access, and Container App revision events. |
| Gateway returns `502` | Gateway or downstream service is cold, unhealthy, or unreachable. | Check gateway revision health and internal target FQDNs. |
| Proxy returns `401` for a browser | No valid `gs_sso` cookie or refresh failed. | Check callback, cookie size, OIDC claim, and proxy logs. |
| Proxy returns `401` for an API | Expected behavior without an OIDC session or machine credential. | Use a valid OIDC session or supported machine credential. |
| Browser gets a Basic dialog | An upstream `WWW-Authenticate` response may be exposed. | Confirm the proxy is running the current response-header filtering code. |
| OIDC callback returns `invalid_callback` | State, nonce, PKCE, redirect URI, or token claim failure. | Check `oidc:callback-claims` and Keycloak redirect settings. |
| Login does not persist | Session cookie too large, wrong secret, or insecure origin. | Search for `session:seal-large`; confirm `Secure` cookies use HTTPS. |
| GeoServer REST returns `401` | Missing OIDC session or invalid Basic credentials. | Test through the proxy and check `headerAuth` chain configuration. |
| OWS returns an ExceptionReport | ACL hides the layer or the layer is not configured. | Check the catalog, ACL rules, workspace, and layer name. |
| WFS-T is denied | No username/role write rule or a broad deny rule matches first. | Inspect ACL priority and `service: WFS`, `request: Transaction`. |
| Machine authkey works on one replica only | User data is cached per OWS/GWC replica. | Rerun security configuration and restart OWS/GWC replicas. |
| Authkey does not work on REST | Expected GeoServer authkey limitation. | Use Basic auth or an OIDC session for REST configuration. |
| Catalog apply partially fails | Resource order is not a transaction. | Fix the resource-specific error and rerun reconciliation. |
| RabbitMQ queue is missing | Broker scaled to zero or restarted without durable state. | Confirm one warm replica and inspect the Azure File share. |
| Wicket page expires | Web UI request reached another replica. | Check sticky-session patch and gateway cookie forwarding. |

## Proxy Log Events

Useful events include:

- `oidc:discovery`
- `oidc:callback-claims`
- `oidc:principal-claim-missing`
- `auth:callback-error`
- `auth:refresh-failed`
- `session:seal-large`
- `handleProxy:redirect-login`
- `handleProxy:401`
- `handleProxy:machine-auth`
- `proxy:upstream-error`

The proxy uses structured JSON logs. Keep `DEBUG_UNSAFE_HEADERS=false`. Sanitized
header logging is sufficient for normal diagnosis.

## Terraform Failures

1. Read the first resource-specific error, not only the final Terraform summary.
2. Check whether the error is control-plane or private data-plane access.
3. Verify the Azure subscription and GitHub OIDC identity.
4. Check the VNet, delegated subnets, private endpoints, and DNS.
5. Run a new plan after the cause is fixed.

Do not use `terraform destroy` to repair a partial apply. Stateful resources have
`prevent_destroy` protections for this reason.

## Catalog Failures

Run validation without external access:

```bash
cd geo-server-app-config
geoserver-apply validate --catalog-dir catalog
```

Then run a dry-run with the target environment. If a live apply fails, read the
resource name and response body. The operation may have already updated earlier
resources. Verify state through GeoServer REST and ACL REST before retrying.

## Security Failures

Check in this order:

1. Proxy health and OIDC discovery.
2. Keycloak redirect URI and required `email` claim.
3. `gs_sso` cookie and refresh events.
4. Gateway reachability and `SharedAuth` route filter.
5. GeoServer `headerAuth` configuration.
6. GeoServer user/group service.
7. ACL rule priority and principal.
8. Machine authkey user data and OWS replica restarts.

## Escalation Data

When opening an incident, provide:

- Environment name and UTC time.
- Request path and method without secrets.
- Correlation/request ID from proxy logs, if available.
- Container App and revision names.
- Terraform plan or apply run URL.
- Sanitized error body and status code.
- Whether the issue affects browser, API, machine client, or direct gateway traffic.
