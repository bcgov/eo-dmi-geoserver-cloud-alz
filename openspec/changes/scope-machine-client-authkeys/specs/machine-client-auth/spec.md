# Delta Specs: Machine-client authentication (new capability)

## ADDED Requirements

### Requirement: Machine-client identities are provisioned independently per username
The system SHALL provision one GeoServer `authkey`-authenticated identity per entry in
`var.machine_client_usernames`, each with its own generated credential, such that adding
or removing a machine client is a one-line change to that list rather than a change to
shared infrastructure.

#### Scenario: A new username is added to the list
- **WHEN** a new username is appended to `var.machine_client_usernames` and Terraform is
  applied
- **THEN** a new Key Vault secret `geoserver-machine-authkey-<username>` is generated (if
  absent) and `configure-geoserver-security.sh` creates a corresponding GeoServer user and
  `authkeys.properties` entry, without modifying any other username's secret, user, or key

#### Scenario: An empty list skips provisioning entirely
- **WHEN** `var.machine_client_usernames` is an empty list
- **THEN** no `null_resource.secret_geoserver_machine_authkey` resources are created and
  `configure-geoserver-security.sh` step 6 is skipped

### Requirement: Machine-client provisioning grants no authorization
The system MUST NOT grant a machine-client identity any GeoServer role or geoserver-acl
access as part of provisioning it (Terraform + `configure-geoserver-security.sh`).
Authorization is a separate concern owned by
`geo-server-app-config/catalog/acl_rules.yaml`.

#### Scenario: A freshly provisioned machine client has no ACL rule yet
- **GIVEN** a username newly added to `var.machine_client_usernames` and applied
- **AND** no corresponding rule yet added to `catalog/acl_rules.yaml`
- **WHEN** that machine client authenticates via `?authkey=<key>` and requests any OWS
  operation on any workspace
- **THEN** geoserver-acl denies the request (no matching ALLOW rule for that username)

### Requirement: The authkey filter is restricted to OWS and tile-cache chains
The shared `authKey` filter SHALL be wired only into the `default` (OWS: WMS/WFS/WCS/WPS)
and `gwc` (tile cache) filter chains, and SHALL NOT be present in the `web` (admin GUI) or
`rest` (config API) chains.

#### Scenario: An authkey does not authenticate against the REST config API
- **GIVEN** a valid `?authkey=<key>` for a provisioned machine-client username
- **WHEN** that key is passed as a query parameter to `/rest/workspaces.json`
- **THEN** the request is treated as unauthenticated (HTTP 401), not as the resolved user

### Requirement: Machine-client Key Vault secrets are generated once and never overwritten
`null_resource.secret_geoserver_machine_authkey` SHALL check for an existing secret named
`geoserver-machine-authkey-<username>` before generating a new one, so re-applying
Terraform never rotates or invalidates a key already in use.

#### Scenario: Re-running apply does not change an existing machine client's key
- **GIVEN** `geoserver-machine-authkey-svc-machine-wildlife` already exists in Key Vault
- **WHEN** `terraform apply` runs again with `svc-machine-wildlife` still in
  `var.machine_client_usernames`
- **THEN** the existing secret value is left unchanged
