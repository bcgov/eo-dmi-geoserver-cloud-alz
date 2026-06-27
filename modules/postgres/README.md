# module: postgres

Azure Database for PostgreSQL Flexible Server reached over a **private endpoint**
(public access disabled). Creates:

- the `geoserver_config` database — GeoServer Cloud `pgconfig` catalog backend,
- the `geodata` database — PostGIS geospatial data,
- the `azure.extensions` allowlist (POSTGIS + friends),
- a generated admin password (sensitive output → stored in Key Vault by the stack).

Stateful resources use `prevent_destroy`. Leave `private_dns_zone_ids` empty to
let the BC Gov platform DNS policy register the endpoint record.

> Verify: private-endpoint connectivity for Flexible Server and the exact
> `subresource_names` value against the azurerm provider version you pin. The
> geospatial extensions still require `CREATE EXTENSION postgis;` to be run once
> against `geodata` (documented in the runbook).
