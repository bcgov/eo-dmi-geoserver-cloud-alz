## ADDED Requirements

### Requirement: Custom image build for JVM-based GeoServer Cloud services
The system SHALL produce container images for the gateway, webui, wms, wfs, wcs, wps, rest, gwc, and acl services by building a custom Dockerfile on top of the pinned upstream `geoservercloud/geoserver-cloud-<service>` (or `geoservercloud/geoserver-acl`) image, instead of importing that upstream image unmodified into the Azure Container Registry (ACR).

#### Scenario: Building a service image
- **GIVEN** a pinned upstream image tag (`var.gs_cloud_version` or `var.acl_version`) and a pinned `var.jaz_version`
- **WHEN** `terraform apply` runs and the service's Dockerfile contents, `jaz` version, or upstream tag have changed since the last apply
- **THEN** an `az acr build` runs against the shared Dockerfile with that service's upstream image as `BASE_IMAGE`, and a new image tagged `${module.registry.login_server}/${repo}:${tag}` is pushed to ACR before the corresponding Container App is created or updated

#### Scenario: Unrelated apply does not rebuild unchanged images
- **GIVEN** a service's Dockerfile contents, `jaz` version, and upstream tag are unchanged since the last apply
- **WHEN** `terraform apply` runs for an unrelated change
- **THEN** the build for that service does not re-run, and its Container App continues referencing the already-built image tag

#### Scenario: Non-JVM images are unaffected
- **GIVEN** the RabbitMQ and PostgreSQL images used elsewhere in the stack
- **WHEN** `terraform apply` runs
- **THEN** those images continue to be populated via the existing `importImage` action, not the custom build path

### Requirement: Per-service rollout control
The system SHALL allow each of the 9 JVM-based services to independently use either its imported upstream image or its custom-built jaz image, so the rollout can proceed one service at a time.

#### Scenario: Partial rollout state
- **GIVEN** one pilot service has been switched to the custom-built image and the remaining 8 have not
- **WHEN** `terraform apply` runs
- **THEN** the pilot service's Container App references the newly built tag, the other 8 continue referencing their imported tags, and neither group's Terraform resources depend on the other
