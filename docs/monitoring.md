# Monitoring and Alerting

The Container Apps environment sends logs to the Log Analytics workspace created
by the observability module. The module creates the workspace only; alert rules,
dashboards, and on-call routing are service-owner responsibilities.

## Signals to Monitor

| Signal | Why it matters | First response |
| --- | --- | --- |
| Proxy `/healthz` availability | Public edge failure. | Check App Service container and Key Vault references. |
| `auth:callback-error` and `oidc:principal-claim-missing` | Keycloak client or claim failure. | Check redirect URIs, protocol mappers, issuer, and client secret. |
| `auth:refresh-failed` | Session expiry or identity-provider outage. | Check Keycloak token endpoint and refresh-token validity. |
| Proxy `502` and `proxy:upstream-error` | Gateway or VNet path failure. | Check gateway revision, DNS, TLS, and internal load balancer. |
| GeoServer startup errors | Service configuration or image incompatibility. | Check mounted config, Spring profiles, and image version. |
| ACL errors or latency | Authorization failure or dependency slowdown. | Check ACL revision, database, and rule payloads. |
| RabbitMQ queue errors | Catalog events may not propagate. | Check broker replica, Azure File mount, and queues. |
| PostgreSQL connection errors | Catalog or data outage. | Check private DNS, server health, connections, and credentials. |
| Container App restarts | Capacity, probe, image, or secret failure. | Inspect revision events and container logs. |
| Key Vault access errors | Secret resolution failure. | Check managed identity role and private endpoint access. |

## Proxy Log Safety

Use `info` for normal operation. Sanitized header logging can be enabled for a
controlled diagnosis. Never enable `DEBUG_UNSAFE_HEADERS` in shared or production
environments because it disables the redaction backstop and can expose cookies
or credentials.

## Retention

The observability module defaults to 30 days and accepts 30 to 730 days. Select
retention by environment and compliance requirement. Longer retention increases
Log Analytics storage cost.

## Alert Ownership

The service owner must define alert thresholds, notification channels, and
response runbooks. At minimum, production should alert on:

- Proxy availability failure.
- Repeated gateway `502` responses.
- OIDC callback or refresh failures above the normal baseline.
- Container App revision failures or repeated restarts.
- PostgreSQL and ACL connectivity failures.
- RabbitMQ queue or event delivery failures.
- Key Vault secret-resolution failures.
