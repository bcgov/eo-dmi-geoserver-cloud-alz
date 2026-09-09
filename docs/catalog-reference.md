# Catalog-as-Code Reference

The `geo-server-app-config` package reconciles YAML catalog state to the
GeoServer gateway and the `geoserver-acl` service. Terraform owns Azure and
runtime infrastructure. Catalog-as-code owns workspaces, stores, layers, styles,
layer groups, and ACL rules.

## Commands

From `geo-server-app-config/`:

```bash
# Install the package and development test dependency.
uv pip install -e .

# Validate YAML and cross-file references without network access.
geoserver-apply validate --catalog-dir catalog

# Show the intended changes without writing to GeoServer.
geoserver-apply run dev \
  --catalog-dir catalog \
  --env-dir environments \
  --stack-dir ../infra/stack \
  --dry-run

# Reconcile the catalog against a live environment.
geoserver-apply run dev \
  --catalog-dir catalog \
  --env-dir environments \
  --stack-dir ../infra/stack
```

`validate` parses the catalog and checks references. `--dry-run` also loads the
environment file and prints the resources that would be processed, but it does
not perform the GeoServer health check or write requests.

A live apply:

1. Resolves `kv://` and `tf://` values.
2. Loads and validates all catalog files.
3. Waits for the GeoServer REST version endpoint.
4. Ensures workspaces.
5. Ensures PostGIS stores.
6. Uploads styles before layers.
7. Ensures feature types and default styles.
8. Ensures layer groups.
9. Ensures ACL rules.

The operation is idempotent at the individual resource level. It is not a
transaction. A later error does not undo earlier successful requests.

## Catalog Files

| File | Top-level key | Purpose |
| --- | --- | --- |
| `workspaces.yaml` | `workspaces` | GeoServer workspace and namespace definitions. |
| `stores.yaml` | `postgis_stores` | PostGIS datastore definitions and environment connection references. |
| `layers.yaml` | `feature_types` | Feature type and layer definitions. |
| `layer_groups.yaml` | `layer_groups` | Published layer groups and styles. |
| `acl_rules.yaml` | `acl_rules` | `geoserver-acl` authorization rules. |
| `styles/*.sld` | file stem | SLD style content. The stem is the style name. |

## Workspace Schema

```yaml
workspaces:
  - name: wildlife
    namespace_uri: https://geo.bc.gov.ca/wildlife
    isolated: false
```

Fields:

- `name`: required GeoServer workspace name.
- `namespace_uri`: required HTTP or HTTPS namespace URI. The project uses the
  `https://geo.bc.gov.ca/<workspace>` pattern.
- `isolated`: optional Boolean. Defaults to `false`.

## PostGIS Store Schema

```yaml
postgis_stores:
  - workspace: wildlife
    name: wildlife_postgis
    connection: default
    expose_primary_keys: true
    fetch_size: 1000
    validate_connections: true
```

Fields:

- `workspace`: existing workspace name.
- `name`: datastore name within the workspace.
- `connection`: key under `postgis_stores` in the selected environment file.
- `expose_primary_keys`: defaults to `true`.
- `fetch_size`: defaults to `1000`.
- `validate_connections`: defaults to `true`.

The datastore connection contains the host, port, database, schema, user,
password, and SSL mode. Keep password values in Key Vault references.

## Feature Type and Layer Schema

```yaml
feature_types:
  - workspace: wildlife
    store: wildlife_postgis
    name: veg_comp_poly
    native_name: veg_comp_poly
    title: Vegetation Composite Polygons (VRI)
    srs: EPSG:3005
    enabled: true
    default_style: basic_polygon
```

Fields:

- `workspace` and `store`: existing references.
- `name`: published feature type and layer name.
- `native_name`: name in the PostGIS store.
- `title`: display title.
- `srs`: defaults to `EPSG:3005`, the BC Albers default used by this project.
- `enabled`: defaults to `true`.
- `default_style`: optional SLD file stem under `catalog/styles/`.

## Layer Group Schema

```yaml
layer_groups:
  - workspace: wildlife
    name: wildlife_overview
    title: Wildlife overview
    mode: SINGLE
    layers:
      - wildlife:veg_comp_poly
    styles:
      - basic_polygon
```

`mode` must be one of `SINGLE`, `OPAQUE_CONTAINER`, `NAMED`, `CONTAINER`, or
`EO`. Every layer reference must use `workspace:layer` and must resolve to a
feature type in the catalog. Style values refer to SLD file stems.

## Styles

Put SLD files under `catalog/styles/`. The file stem is the GeoServer style name:

```text
catalog/styles/basic_polygon.sld -> basic_polygon
```

Styles are uploaded before feature types. A feature type's `default_style` must
match an existing SLD stem. The reconciliation process updates the style body
when the file changes.

## Environment Files and Secret References

Each environment file contains:

- `env`: the environment name.
- `gateway_url`: normally a `tf://gateway_url` reference.
- GeoServer admin credentials.
- ACL service URL and credentials.
- PostGIS connection values.
- HTTP timeout and retry settings.

Supported references are:

```text
kv://<vault-name>/<secret-name>
tf://<terraform-output-name>
```

`kv://` is resolved with `DefaultAzureCredential`. `tf://` runs Terraform output
against the stack directory. Literal values are accepted, but do not put secrets
in the repository.

The `dev`, `test`, and `prod` files use separate Key Vault names. A new
environment requires a matching Terraform state, Key Vault, Terraform outputs,
and environment YAML file.

## ACL Rules

Every rule must set exactly one principal:

- `role`: every principal with the role.
- `username`: one exact principal, normally a machine-client identity.

Example:

```yaml
acl_rules:
  - priority: 5
    username: svc-machine-wildlife
    workspace: wildlife
    layer: "*"
    access: WRITE
  - priority: 18
    role: ROLE_AUTHENTICATED
    workspace: wildlife
    layer: "*"
    service: WFS
    request: Transaction
    access: DENY
  - priority: 20
    role: ROLE_AUTHENTICATED
    workspace: wildlife
    layer: "*"
    access: READ
```

Rules use lower numbers first. Use this order when a broad read rule must not
allow a write operation:

1. Specific machine or editor `ALLOW` rule.
2. Narrow `DENY` for the write operation.
3. Broad authenticated read `ALLOW` rule.

`access: READ` is mapped to an ACL `ALLOW` rule. It does not by itself restrict
the OWS request to read operations. Use `service` and `request` to narrow a
rule. The `layer: "*"` value is converted to an absent layer field for the ACL
API.

## Machine Client Lifecycle

### Add a client

1. Add the username to Terraform `machine_client_usernames`.
2. Apply the environment. Terraform creates a Key Vault secret named
   `geoserver-machine-authkey-<username>`.
3. Run the GeoServer security configuration so the GeoServer user and key are
   present on every OWS replica.
4. Add a username-scoped ACL rule for the required workspace and operation.
5. Run catalog validation, dry-run, and apply.
6. Test both the allowed operation and an operation outside the scope.

### Rotate a client key

1. Remove the ACL grant or make it deny access.
2. Generate or replace the Key Vault secret through an approved rotation process.
3. Rerun the security configuration. The OWS services must restart when user/key
   data changes because user data is cached per replica.
4. Test the new key and confirm the old key is rejected.
5. Restore the ACL grant only after the new key works.

### Revoke a client

Revoke in this order so the credential stops being useful before it is removed:

1. Remove the username-scoped ACL rule through the ACL API.
2. Delete the GeoServer user from the default user/group service.
3. Remove the username from Terraform and remove its Key Vault secret.
4. Test that the old key cannot access OWS.

The current reconciliation tool does not prune deleted ACL rules. Terraform does
not delete the GeoServer user when a username is removed from its variable.

## Failure Recovery

If validation fails, fix the YAML shape or references and rerun `validate`.

If dry-run fails, fix environment-file or Terraform-output access before making
network requests.

If apply reports errors:

1. Read the resource-specific error and response body.
2. Check gateway and ACL health.
3. Confirm the resolved Key Vault and Terraform values.
4. Rerun the same command after fixing the cause.
5. Verify the final state through GeoServer REST and ACL REST calls.

There is no catalog rollback command. Roll back by reverting the catalog files in
Git and running another reconciliation, then remove any ACL rules manually when
the desired state no longer contains them.

## Reference Implementation

- [geoserver_catalog_schema.py](../geo-server-app-config/geoserver_catalog_schema.py)
- [reconcile.py](../geo-server-app-config/reconcile.py)
- [geoserver_client.py](../geo-server-app-config/geoserver_client.py)
- [geo-server-app-config/README.md](../geo-server-app-config/README.md)
