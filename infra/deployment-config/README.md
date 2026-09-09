# Deployment Config Bundle

This directory holds the deployment-time Spring YAML config bundle for the
GeoServer Cloud services. Terraform publishes these files to an Azure File share
and mounts the share read-only at:

```text
/etc/gscloud/deployment-config/
```

The services consume the files through Spring Boot config import. The shared
service environment sets `SPRING_CONFIG_ADDITIONAL_LOCATION` to this path.

## Files

| File | Consumer or purpose |
| --- | --- |
| `gateway.yml` | WebMVC gateway routes, forwarded headers, gateway targets, and `SharedAuth`. |
| `gateway-webflux.yml` | WebFlux gateway alternative and route defaults. |
| `geoserver.yml` | GeoServer runtime, pgconfig, ACL, event bus, and extension settings. |
| `geoserver_spring.yml` | Spring and GeoServer service defaults imported by GeoServer. |
| `geoserver_logging.yml` | Logging configuration imported by gateway and GeoServer services. |
| `jndi.yml` | JNDI datasource configuration for the pgconfig backend. |

## Publication

Terraform uploads the bundle when the content hash changes. A normal apply is
required after editing these files. Container Apps then read the mounted files
when the service starts; restart the affected services if a running revision does
not reload the changed configuration.

Do not put secrets in this directory. Use environment variables and Key Vault
references. Do not change gateway route paths without updating the proxy contract,
integration tests, and catalog URLs.
