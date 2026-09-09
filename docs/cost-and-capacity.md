# Cost and Capacity Guide

The stack uses Azure Container Apps, PostgreSQL Flexible Server, App Service,
Log Analytics, ACR, Key Vault, Azure Storage, and a Bastion-based private access
path. Costs depend on replica count, CPU, memory, storage, log volume, and
PostgreSQL SKU.

## Main Cost Controls

| Setting | Source | Effect |
| --- | --- | --- |
| `service_cpu` and `service_memory` | `infra/stack/variables.tf` | Per-replica ACA compute. ACA Consumption CPU and memory pairs must be valid. |
| `service_min_replicas` | Terraform variables | Warm capacity versus scale-to-zero. Gateway, Web UI, OWS, ACL, and RabbitMQ have service-specific overrides. |
| `service_max_replicas` | Terraform variables and `locals.tf` | Maximum ACA replicas and burst capacity. |
| `postgres_sku_name` | Terraform variables | PostgreSQL compute, memory, and cost. |
| `postgres_enable_high_availability` | Terraform variables | Adds standby capacity and improves availability. |
| `zone_redundancy_enabled` | Terraform variables | Increases resilience and may increase cost. |
| Log Analytics retention | Observability module | Longer retention increases stored log cost. |
| GeoWebCache storage | Deployment and storage config | Ephemeral cache has low storage cost but loses cache on restart. Azure Files adds storage and transaction cost. |
| RabbitMQ Azure File share | `rabbitmq-storage.tf` | Durable broker data and storage transaction cost. |
| Proxy App Service SKU | `proxy_sku` | Public edge compute and VNet integration capacity. |

## Capacity Rules

- Keep the gateway warm. A cold gateway can look like a proxy `502` during its
  startup window.
- Keep ACL warm. It is on the authorization path for secured OWS requests.
- Keep RabbitMQ at one replica. Its TCP ingress has no scale trigger and catalog
  event queues can stop when it scales to zero.
- Keep Web UI at one replica or use the sticky-session workaround. Wicket page
  state is not safe to distribute without affinity.
- Size WMS, WFS, and WCS separately. Rendering and large feature responses can
  need more CPU and memory than REST or WPS.
- Use load tests before raising maximum replicas. A higher ceiling increases
  possible cost and may expose database or event-bus limits.

## Production Starting Point

The current `locals.tf` map is the starting point for the project POC:

- Gateway: 2 CPU, 4 GiB, one to three replicas.
- Web UI: 2 CPU, 4 GiB, one to two replicas.
- WMS: 2 CPU, 4 GiB, one to four replicas.
- WFS: 2 CPU, 4 GiB, one to three replicas.
- WCS: 2 CPU, 4 GiB, one to two replicas.
- WPS: 2 CPU, 4 GiB, one to two replicas.
- REST: 2 CPU, 4 GiB, one to two replicas.
- GWC: 2 CPU, 4 GiB, one to three replicas.
- ACL: one replica in the current stack.

These values are not a capacity guarantee. Record measured request volume,
response size, latency, and database utilization before changing them.

## Scaling Review Checklist

Before changing capacity:

1. Confirm the target service and request type.
2. Check Container App CPU, memory, replica, and restart metrics.
3. Check PostgreSQL connections and query latency.
4. Check RabbitMQ queue depth and event delivery.
5. Check ACL response latency.
6. Check Log Analytics volume and retention.
7. Apply changes in `dev` and run the integration suite.
8. Review cost impact before promoting to `prod`.
