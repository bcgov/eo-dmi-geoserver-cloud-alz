# Module: Observability

Creates the Log Analytics workspace that the Container Apps environment streams
logs to. The module does not create alert rules, dashboards, or workbooks.
Those remain an operational responsibility.

## Inputs

| Input | Required | Default | Notes |
| --- | --- | --- | --- |
| `name` | Yes | None | Workspace name. |
| `resource_group_name` | Yes | None | Workload resource group. |
| `location` | Yes | None | Azure region. |
| `retention_in_days` | No | `30` | Valid range is 30 to 730 days. |
| `tags` | Yes | None | Naming module common tags. |

The workspace uses the `PerGB2018` SKU. Retention affects storage cost and must
match the approved environment policy.

## Outputs

- `id`, `log_analytics_id`: workspace resource ID.
- `workspace_id`: Log Analytics workspace GUID.
- `log_analytics_workspace_key`: sensitive primary shared key output.

The shared key is sensitive and must not be printed or committed. Prefer managed
identity and Azure Monitor access for operational queries.

## Operational Ownership

The service owner must define:

- Log Analytics retention per environment.
- Queries for proxy, gateway, GeoServer, ACL, RabbitMQ, and Container App health.
- Alerts for availability, repeated restarts, gateway `502`, OIDC failures,
  ACL failures, and database connectivity.
- On-call routing and response actions.
