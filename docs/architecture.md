# Architecture — GeoServer Cloud on Azure Container Apps (BC Gov ALZ)

## Topology

GeoServer Cloud 3.0.0 is deployed in **standalone mode** onto an **Azure
Container Apps environment** with an **internal load balancer** (no public IPs),
inside a platform-provided spoke VNet.

```
                 VNet (platform-provided, locked networking RG)
   ┌───────────────────────────────────────────────────────────────┐
   │  Container Apps environment (workload profiles, INTERNAL LB)    │
   │                                                                 │
   │   gateway* ──► web-ui, wms, wfs, wcs, wps, rest, gwc            │
   │      │             │   │                                        │
   │      │             │   └──► acl (authorization service)         │
   │      └─────────────┴──► rabbitmq (event bus, AMQP 5672)         │
   │                                                                 │
   └──────────┬───────────────────────────┬──────────────────────────┘
              │ private endpoint          │ private endpoint
        PostgreSQL Flexible Server     Key Vault (secrets)
        (pgconfig catalog + PostGIS)
   Standard ACR (admin creds) ──► holds the GeoServer Cloud images
        ▲ images imported by Terraform (modules/registry, azapi importImage)

   * only the gateway is exposed on the environment's INTERNAL load balancer.
```

## Components

| Concern | Resource | Module |
| --- | --- | --- |
| Tags / naming | Mandatory ALZ tags + name prefix | `modules/naming` |
| Networking | Data sources over the platform VNet/subnets (RG never modified) | `modules/network` |
| Logs | Log Analytics workspace | `modules/observability` |
| Images | Standard ACR (admin creds, no PE) + Terraform image import | `modules/registry` |
| Secrets | Key Vault + private endpoint + RBAC | `modules/keyvault` |
| Catalog/data | PostgreSQL Flexible Server (pgconfig + PostGIS) + private endpoint | `modules/postgres` |
| Runtime | Container Apps environment (internal LB) + shared user-assigned identity | `modules/container-app-environment` |
| Event bus | RabbitMQ (Container App) | `modules/rabbitmq` |
| Services | One Container App per GeoServer Cloud microservice | `modules/geoserver-service` |

## Standalone mode

No Consul / Spring Cloud Config server is deployed. Service discovery is provided
by Azure Container Apps' internal DNS (the documented Kubernetes deployment
path). The `pgconfig` backend stores the GeoServer catalog in PostgreSQL, and
RabbitMQ propagates catalog-change events between services. The **GeoServer ACL**
service provides authorization, connecting to the same PostgreSQL server under an
`acl` schema.

Service-to-service calls use the target app's **internal FQDN** (ACA terminates
ingress at 443 / 5672), not compose-style `name:port`.

## Image flow (Terraform-native)

The GeoServer Cloud image set (8 OWS services + `geoserver-acl` + `rabbitmq`) is
defined in `stack/locals.tf` (`registry_images`) from the pinned versions
in `terraform.tfvars`, and passed to `modules/registry`. The module imports each
image into the ACR using the server-side `importImage` action via the `azapi`
provider — equivalent to `az acr import`, but executed by `terraform apply`. The
application modules `depends_on` the registry module, guaranteeing images exist
before the Container Apps start. This replaces the former two-phase
`apply → import-images.sh → apply` workflow.

## Security posture

- No public IPs; only the gateway is reachable, over the VNet's internal LB.
- Private endpoints + private DNS for PostgreSQL and Key Vault.
- OIDC federated identity for all state access and deploys (no client secrets,
  no storage keys — `use_azuread_auth`).
- All secrets (ACR, PostgreSQL, RabbitMQ, ACL users) generated/stored in Key
  Vault and surfaced to apps as versionless Key Vault references.
- `prevent_destroy` on stateful resources.

See [`runbook.md`](runbook.md) for the bootstrap and deploy procedure and the
bootstrap-vs-hardened tradeoffs.
