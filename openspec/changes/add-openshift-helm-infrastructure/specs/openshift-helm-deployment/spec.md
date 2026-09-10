# Spec: OpenShift Helm Deployment

## ADDED Requirements

### Requirement: The OpenShift Helm chart has a validated configuration contract

The repository MUST provide two Helm charts: `infra/helm/crunchy-postgres/` for
the vendored BC Gov `action-crunchy` templates and `infra/helm/geoserver-cloud/`
for the application workloads. Each chart MUST have its own `Chart.yaml`, values,
schema, templates, and documentation. The GeoServer
values schema MUST validate image references, service settings, resource settings,
database release-name inputs, Secret references, proxy OIDC settings, and proxy
exposure settings.

#### Scenario: Representative chart values lint and render successfully

- **GIVEN** the two charts have representative development values and the Crunchy release is named `crunchy-postgres`
- **WHEN** an operator lints/renders `infra/helm/crunchy-postgres` first and then lints/renders `infra/helm/geoserver-cloud` with `database.crunchyReleaseName=crunchy-postgres`
- **THEN** both commands exit successfully and each rendered output contains only valid Kubernetes or OpenShift resource documents

#### Scenario: Vendored Crunchy templates render reproducibly

- **GIVEN** `infra/helm/crunchy-postgres/` contains the reviewed `action-crunchy` templates at the documented source commit
- **WHEN** an operator runs `helm lint` and `helm template` for the Crunchy chart
- **THEN** Helm renders the `PostgresCluster` and names its cluster and generated services from the release without contacting an external chart repository

#### Scenario: Invalid values are rejected before installation

- **GIVEN** a values file contains an invalid image tag type, a negative replica count, or a missing required Secret reference
- **WHEN** an operator runs `helm lint` or `helm template` with that values file
- **THEN** Helm exits non-zero with an error identifying the invalid value

### Requirement: The two Helm releases render the complete OpenShift stack

The Crunchy chart MUST render the `PostgresCluster` and its operator dependency
resources. The GeoServer chart MUST render Deployments for `oidc-proxy`, `gateway`, `webui`, `wms`,
`wfs`, `wcs`, `wps`, `rest`, `gwc`, and `acl`; RabbitMQ stateful resources; the pinned Crunchy
Postgres connection references; ClusterIP Services for every application workload;
the shared configuration ConfigMap; and the required PDB, HPA, PVC, and
image-pull Secret-reference resources.

#### Scenario: Full-stack values render all required workloads

- **GIVEN** the Crunchy chart was installed with release name `crunchy-postgres` and the GeoServer chart is rendered with the same release-name input
- **WHEN** an operator inspects the rendered resource names and kinds
- **THEN** the combined outputs contain the Crunchy PostgresCluster, generated Secret contract, Node OIDC proxy Deployment, eight GeoServer Cloud Deployments, one ACL Deployment, one RabbitMQ StatefulSet, and a Service for each application workload

### Requirement: The Node OIDC proxy is the chart-managed edge entry point

The chart MUST expose the gateway and backend services only through namespace-local
ClusterIP Services. The chart MUST render the Node OIDC proxy with its OIDC,
session, and gateway-origin configuration, and MUST NOT render a NodePort or
LoadBalancer Service. The chart MAY render one OpenShift `Route` for the proxy
when explicitly enabled, and MUST NOT render a Route for the gateway, webui, WMS,
WFS, WCS, WPS, REST, GWC, ACL, PostgreSQL, or RabbitMQ.

#### Scenario: Explicit proxy Route creates one authenticated edge resource

- **GIVEN** proxy Route exposure is enabled with an approved hostname and TLS mode
- **WHEN** the chart is rendered
- **THEN** exactly one OpenShift `Route` targets the `oidc-proxy` ClusterIP Service, the gateway remains ClusterIP-only, and all backend Services remain namespace-local

#### Scenario: Default installation has no accidental edge exposure

- **GIVEN** proxy Route exposure is not enabled
- **WHEN** the chart is rendered
- **THEN** no `Route`, `NodePort` Service, or `LoadBalancer` Service is present in the output

### Requirement: Service discovery uses OpenShift Service DNS names

The chart MUST configure the gateway and GeoServer services to use stable
namespace-local Service names, including `wms:8080`, `wfs:8080`, `wcs:8080`,
`wps:8080`, `rest:8080`, `gwc:8080`, `webui:8080`, and
`acl:8080/acl/api`. Database clients MUST use the
`crunchy-postgres-pgbouncer` Service for PostgreSQL. The chart MUST NOT require Azure Container Apps internal
FQDNs or ACA-specific load-balancer discovery.

#### Scenario: Rendered gateway configuration points to Kubernetes Services

- **GIVEN** the chart is rendered with the default in-cluster topology
- **WHEN** an operator reads the gateway ConfigMap and environment values
- **THEN** every gateway backend target resolves to the corresponding OpenShift Service DNS name, PostgreSQL settings target `crunchy-postgres-pgbouncer:5432`, and no target contains `.internal.` or an ACA default domain

### Requirement: Images are pulled through BC Gov Platform Artifactory

The chart MUST accept pinned Artifactory image repositories and tags or digests for
every container and MUST attach the configured image-pull Secret to every workload
that needs registry authentication. Docker Hub-origin images MUST use the
`artifacts.developer.gov.bc.ca/<remote-repository>/<image>:<tag>` form. Crunchy
Postgres, pgBackRest, pgBouncer, and related images MUST use approved
`artifacts.developer.gov.bc.ca/bcgov-docker-local/<image>:<tag>` paths. No rendered
workload may reference `docker.io`, `registry-1.docker.io`, or an unapproved image
registry host. The project-built Node OIDC proxy image MUST use the approved
`artifacts.developer.gov.bc.ca/bcgov-docker-local/node-oidc-proxy:<tag>` path.
Runtime credentials MUST be read through `secretKeyRef` entries from
the chart-created `geoserver-cloud-runtime` Secret for application credentials.
The Crunchy-generated database Secret and platform image-pull Secret remain
external Secret owners. The chart MUST NOT contain fixed credential values in
committed values files or require credentials through Helm `--set` values.

The chart MUST accept an optional `secrets.runtime.oidcClientSecret` string for
first-install bootstrap. Operators MUST be able to pass it with Helm
`--set-string`, including by expanding a terminal environment variable. If the
value is omitted, the chart MAY generate one. Existing Secret data MUST take
precedence on upgrades.

#### Scenario: Rendered workloads use Artifactory image paths

- **GIVEN** the operator supplies approved Artifactory remote and local repository paths and immutable image versions
- **WHEN** the chart and its Crunchy dependencies are rendered
- **THEN** every container image starts with `artifacts.developer.gov.bc.ca/`, Docker Hub-origin images use the configured remote repository, the proxy and Crunchy images use `bcgov-docker-local`, and no direct Docker Hub reference is present

#### Scenario: Rendered workloads reference credentials without embedding them

- **GIVEN** the chart is installed with the configured runtime Secret name and the
  Crunchy and platform Secret prerequisites
- **WHEN** the chart is rendered
- **THEN** application container environment entries use `secretKeyRef` to the
  runtime Secret, database entries use the Crunchy-generated Secret, image-pull
  references use the platform Secret, and no credential value is committed to
  values files

#### Scenario: OIDC client secret can be supplied at first install

- **GIVEN** `OIDC_CLIENT_SECRET` is set in the operator terminal
- **WHEN** the operator passes `--set-string secrets.runtime.oidcClientSecret="$OIDC_CLIENT_SECRET"`
- **THEN** the rendered `geoserver-cloud-runtime` Secret uses that value for
  `oidc-client-secret` and the proxy references that key with `secretKeyRef`

#### Scenario: Existing OIDC client secret survives upgrade

- **GIVEN** `geoserver-cloud-runtime` already exists with `oidc-client-secret`
- **WHEN** the chart is upgraded with a different or omitted
  `secrets.runtime.oidcClientSecret` value
- **THEN** the existing Secret value remains unchanged

#### Scenario: Artifactory pull credentials are explicitly attached

- **GIVEN** the platform provides a cluster-wide remote-cache Secret or an `ArtifactoryServiceAccount` generates an `artifacts-*` Secret in the namespace
- **WHEN** the chart is rendered for an application workload or Crunchy dependency workload
- **THEN** the workload has the configured Secret under `imagePullSecrets`, and the operator procedure identifies any required service-account Secret link

### Requirement: Crunchy Postgres provides HA PostgreSQL/PostGIS and recovery

The chart MUST configure the BC Gov `crunchy-postgres` dependency for the selected
PostgreSQL and PostGIS versions, an approved instance replica count, per-instance
storage and resources, and pgBackRest backup retention and schedules. The chart
MUST use the `crunchy-postgres-pgbouncer` Service for application connections and
MUST create the `pgconfig` and `acl` schemas through a supported Crunchy
initialization path or a namespaced, hardened one-shot Job after the pgBouncer
Service is available. The chart
MUST NOT define a competing hand-written PostgreSQL StatefulSet.

#### Scenario: Crunchy values render an HA database and backup path

- **GIVEN** the chart is rendered with approved Crunchy versions, at least two database instances, storage settings, and pgBackRest repository settings
- **WHEN** an operator inspects the dependency output
- **THEN** the output contains the Crunchy primary and replica resources, per-instance persistent storage, PostGIS-capable Artifactory images, pgBackRest backup resources, and no custom PostgreSQL StatefulSet from the parent chart

#### Scenario: Database initialization is namespaced and idempotent

- **GIVEN** the Crunchy pgBouncer Service is available and the `pgconfig` and `acl` schemas are absent or already present
- **WHEN** the chart initialization mechanism runs
- **THEN** it creates or verifies both schemas without a public database endpoint and can run again without destructive changes

### Requirement: Stateful services retain data through pod replacement

Crunchy Postgres and RabbitMQ MUST use stable service names and persistent claims
for each stateful instance. RabbitMQ MUST run as a StatefulSet with a
`volumeClaimTemplate`; Crunchy Postgres MUST own its PostgreSQL data claims through
the dependency chart. RabbitMQ MUST remain single-replica until a reviewed
clustering and peer-discovery design exists. A database or broker MUST NOT be
rendered as a single-replica Deployment using a shared ReadWriteOnce PVC.

#### Scenario: Rendered stateful resources have independent persistent storage

- **GIVEN** the full-stack profile is rendered with approved storage class and PVC sizes
- **WHEN** an operator inspects the PostgreSQL and RabbitMQ manifests
- **THEN** RabbitMQ has a per-pod `volumeClaimTemplate`, Crunchy Postgres has per-instance data claims and a PostGIS-capable image, and no stateful workload is a Deployment with a shared ReadWriteOnce volume

#### Scenario: Stateful pod replacement keeps the data mount

- **GIVEN** a PostgreSQL or RabbitMQ pod is replaced without deleting its PVC
- **WHEN** the StatefulSet controller recreates the pod
- **THEN** the replacement pod mounts the existing claim for the same ordinal and retains the service data

### Requirement: Workloads satisfy the restricted-v2 security contract

Every chart-managed container MUST set `allowPrivilegeEscalation: false`,
`capabilities.drop: ["ALL"]`, `runAsNonRoot: true`,
`readOnlyRootFilesystem: true`, and `seccompProfile.type: RuntimeDefault`. Pod
templates MUST NOT hard-code `runAsUser`, `runAsGroup`, `fsGroup`, or
`supplementalGroups`. Writable application paths MUST use explicit bounded
`emptyDir` mounts or the stateful workload's PVC.

#### Scenario: Rendered containers are admitted without fixed UID or privilege requests

- **GIVEN** the chart is rendered for a namespace using the `restricted-v2` SCC
- **WHEN** an operator reviews the container and pod security contexts
- **THEN** every container has the required hardening fields, no fixed UID/GID fields are present, and writable paths have explicit volumes

#### Scenario: Server-side OpenShift dry run accepts the security posture

- **GIVEN** the target namespace, quota, image policy, and Secret references are available
- **WHEN** an operator pipes the rendered output to `oc apply --dry-run=server -f -`
- **THEN** OpenShift accepts the manifests without an SCC or privilege validation error

### Requirement: Deployments have health, disruption, scaling, and termination controls

Each stateless GeoServer Cloud, ACL, and Node OIDC proxy Deployment MUST have
configurable startup, liveness, and readiness probes. GeoServer and ACL defaults
must be compatible with the Spring Boot actuator health endpoints, and the proxy
default must use its unauthenticated `/healthz` endpoint. Stateless containers
MUST use a termination grace period of at most 60 seconds. Multi-replica
Deployments MUST have a non-zero PDB, pod anti-affinity, and an HPA with explicit
scale-up and scale-down behavior; production HPA minimum replicas MUST be at least
two.

#### Scenario: Rendered stateless workloads have bounded availability behavior

- **GIVEN** production values request at least two replicas for a GeoServer, ACL, or proxy Deployment
- **WHEN** the chart is rendered
- **THEN** the Deployment has startup, liveness, and readiness probes, termination grace no greater than 60 seconds, pod anti-affinity, a PDB with a non-zero disruption budget, and an HPA with explicit scale-up and scale-down behavior

#### Scenario: Slow JVM startup does not trigger premature restarts

- **GIVEN** a GeoServer Cloud or proxy container needs the configured startup budget to initialize
- **WHEN** the pod starts
- **THEN** the startup probe gates liveness until the startup budget is exhausted or the actuator liveness endpoint succeeds, and a temporary downstream database or RabbitMQ failure does not cause the liveness probe to restart a healthy process

### Requirement: Stateful lifecycle settings protect persistent services

Crunchy Postgres and RabbitMQ stateful resources MUST set explicit termination
grace periods no greater than 600 seconds and MUST have PDB settings appropriate
to their configured replica count. Stateful workloads MUST NOT be placed behind an
HPA that changes their replica count from CPU or memory utilization.

#### Scenario: Stateful upgrade preserves orderly termination

- **GIVEN** a Crunchy Postgres or RabbitMQ stateful workload is upgraded to a new pinned image or chart version
- **WHEN** the controller replaces a pod
- **THEN** the pod receives a bounded graceful termination window, the replacement observes the dependency or StatefulSet readiness behavior, and the chart does not create an HPA for the stateful workload

### Requirement: The operator workflow supports validation, installation, and rollback

The chart documentation and deployment script MUST define Artifactory, proxy image,
OIDC, Secret, and ordered Crunchy-first deployment prerequisites, vendored
`action-crunchy` template updates, `helm lint`, `helm template`,
`oc apply --dry-run=server`, installation with `helm upgrade --install --wait` and
a bounded timeout, authenticated proxy smoke checks, pgBackRest backup and restore,
and `helm rollback`. The rollback procedure MUST preserve PVCs and MUST warn that
database schema or Crunchy chart changes require backup or a supported database
restore.

#### Scenario: A release can be validated before cluster mutation

- **GIVEN** an operator has representative environment values and an OpenShift namespace
- **WHEN** the operator runs Helm lint, renders the manifests, checks Artifactory image paths, and performs the server-side dry run
- **THEN** chart syntax, dependency rendering, SCC admission, quota, image policy, and registry pull-reference errors are detected before the Helm release changes the cluster

#### Scenario: Application rollback does not delete persistent data

- **GIVEN** a Helm release has a failed stateless application upgrade and an earlier known-good revision
- **WHEN** the operator runs `helm rollback` without deleting the release or PVCs
- **THEN** stateless workloads return to the earlier chart revision and Crunchy Postgres/RabbitMQ persistent claims remain available to the stateful resources

### Requirement: The OpenShift path remains parallel to Azure infrastructure

Adding or changing the Helm chart MUST NOT change Azure Container Apps Terraform
resources, Terraform backend state, Azure Key Vault references, Azure Container
Registry imports, the Python catalog-as-code package, or the existing GitHub
Actions deployment workflows.

#### Scenario: Helm-only changes leave the Azure deployment path unchanged

- **GIVEN** an implementation changes files under `infra/helm/geoserver-cloud/` and its documentation only
- **WHEN** the existing Azure Terraform validation is run
- **THEN** Terraform module sources and resource definitions remain unchanged and the Azure deployment workflow requires no new environment or secret
