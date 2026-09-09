# GeoServer Cloud Configuration

This document maps the deployed GeoServer Cloud services to their configuration
sources. It describes the current standalone profile and the mounted Spring
configuration bundle.

## Service Matrix

| Service | Ingress | Gateway path | ACL | Notes |
| --- | --- | --- | --- | --- |
| `gateway` | Environment internal load balancer | `/geoserver/cloud/*` | Gateway route security | Only public edge target; reachable through the VNet. |
| `webui` | Internal | `/geoserver/cloud/web/**` | Header auth | Wicket UI; sticky sessions required. |
| `wms` | Internal | `/geoserver/cloud/wms...` | Enabled | WMS rendering. |
| `wfs` | Internal | `/geoserver/cloud/wfs...` | Enabled | WFS and WFS-T. |
| `wcs` | Internal | `/geoserver/cloud/wcs...` | Enabled | Coverage service. |
| `wps` | Internal | `/geoserver/cloud/wps...` | Disabled in the service map | Uses standalone and pgconfig profiles; data-layer ACL is disabled. |
| `rest` | Internal | `/geoserver/cloud/rest/**`, `/api/**`, `/ows/**` | Header auth | Catalog and configuration REST service. |
| `gwc` | Internal | `/geoserver/cloud/gwc/**` | Enabled | Tile cache. |
| `acl` | Internal | `/geoserver/cloud/acl/**` | ACL service auth | Separate authorization service. |
| `rabbitmq` | Internal service path | AMQP 5672 | Broker credentials | Catalog event bus; keep one replica warm. |

The gateway strips the base path before forwarding to downstream services. The
Node proxy preserves the public path and does not rewrite `/geoserver/cloud`.

## Configuration Sources

| Source | Purpose |
| --- | --- |
| `infra/stack/locals.tf` | Service map, replica counts, internal target FQDNs, common environment. |
| `infra/stack/variables.tf` | Environment inputs, versions, sizing, and feature flags. |
| `infra/deployment-config/gateway.yml` | WebMVC gateway routes and filters. |
| `infra/deployment-config/gateway-webflux.yml` | WebFlux gateway alternative. |
| `infra/deployment-config/geoserver.yml` | GeoServer runtime and extension settings. |
| `infra/deployment-config/geoserver_spring.yml` | Spring service defaults. |
| `infra/deployment-config/geoserver_logging.yml` | Logging settings. |
| `infra/deployment-config/jndi.yml` | pgconfig datasource configuration. |
| `infra/stack/rabbitmq-storage.tf` | Azure File shares and deployment-config publication. |

Terraform publishes the deployment-config bundle to an Azure File share and
mounts it read-only at `/etc/gscloud/deployment-config/`.

## Active Spring Profiles

The default profile value is:

```text
standalone,pgconfig,acl,environment-admin-auth
```

The `wps` service overrides this to disable ACL:

```text
standalone,pgconfig,environment-admin-auth
```

The `environment-admin-auth` profile reads the GeoServer admin username and
password from environment variables backed by Key Vault. This avoids relying on
an ephemeral local data directory for a consistent admin credential across
replicas.

## pgconfig and Databases

The `pgconfig` profile stores the GeoServer catalog in the PostgreSQL config
database. GeoServer data and PostGIS tables use the data database. The ACL
service uses its own schema.

The common service environment supplies:

- `PGCONFIG_HOST`
- `PGCONFIG_PORT`
- `PGCONFIG_DATABASE`
- `PGCONFIG_USERNAME`
- `PGCONFIG_SCHEMA=pgconfig`
- `PGCONFIG_INITIALIZE=true`
- `RABBITMQ_HOST`, `RABBITMQ_PORT`, and `RABBITMQ_USER`
- `ACL_URL`, `ACL_USERNAME`, and `ACL_ENABLED=true`

Passwords are supplied through Key Vault-backed environment secrets.

The PostGIS initialization job creates the PostGIS extension in both configured
databases. When `reset_pgconfig_schema=true`, it drops the `pgconfig` schema
before initialization. This is destructive and is intended only for a planned
major catalog migration.

## Gateway Route Security

The gateway routes use:

- `StripBasePath` before downstream calls.
- `SharedAuth` on WMS, WFS, WCS, WPS, REST, GWC, and Web UI routes.
- Forwarded-header handling so the public origin is preserved.
- Secure response headers and CORS settings from the deployment bundle.

The `SharedAuth` filter is part of the GeoServer Cloud gateway image. The proxy
is responsible for validating OIDC and stripping spoofable headers before the
request reaches this route layer. GeoServer's `headerAuth` filter is the
application authentication boundary after the gateway.

## Scaling and Persistence

- `gateway` stays at one minimum replica to avoid proxy-visible cold starts.
- `webui` stays warm and uses sticky sessions for Wicket state.
- OWS services have per-service replica limits in `locals.tf`.
- RabbitMQ stays at one minimum replica because the TCP ingress has no scale
  trigger and catalog event queues can be lost at zero replicas.
- GeoWebCache uses `/tmp/geowebcache` by default and is ephemeral per replica.
- RabbitMQ data uses an Azure File share. The current proof-of-concept storage
  path requires production private-endpoint hardening.

## Change Procedure

1. Identify the consuming service in the service matrix.
2. Edit the correct Terraform or deployment-config source.
3. Run Terraform format and validation.
4. Apply in `tools` or `dev` first.
5. Check revision health and logs.
6. Run catalog and integration checks.
7. Promote through the gated environment workflow.

Do not edit a running container's data directory as a permanent configuration
change.
