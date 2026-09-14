## Why

The project currently describes and provisions GeoServer Cloud only on Azure Container Apps. A parallel OpenShift deployment path is needed for environments that run workloads on the BC Gov OpenShift platform, while preserving the existing Azure deployment and its Terraform state.

## What Changes

- Add two Helm charts for the OpenShift path: a Crunchy Postgres chart that
  vendors the PostgreSQL/PostGIS templates from `bcgov/action-crunchy`, and a GeoServer chart for the Node
  OIDC proxy, gateway, webui, WMS, WFS, WCS, WPS, REST, GWC, ACL, and RabbitMQ.
  The GeoServer chart receives the Crunchy release name and derives the pgBouncer
  Service and generated user Secret names.
- Pull Docker Hub-origin images through the BC Gov Platform Artifactory endpoint `artifacts.developer.gov.bc.ca`, using the approved remote repository path and namespace pull-secret contract. Do not reference Docker Hub directly in rendered workloads.
- Use the vendored BC Gov `action-crunchy` templates for PostgreSQL/PostGIS, HA
  replicas, pgBouncer, and pgBackRest backup configuration instead of maintaining
  a hand-written PostgreSQL StatefulSet or an external chart dependency.
- Define environment-specific chart values for Artifactory image paths and immutable tags or digests, replica counts, resource requests with optional limits, service endpoints, storage and backup settings, and proxy exposure.
- Create one Helm-managed runtime OpenShift Secret for RabbitMQ, GeoServer, ACL,
  and Node OIDC proxy credentials. Keep Crunchy database and platform image-pull
  Secrets under their existing owners, and do not place credential values in
  committed environment files.
- Deploy stateless GeoServer Cloud and ACL workloads as hardened Deployments, RabbitMQ as a persistent stateful workload, and PostgreSQL/PostGIS through the BC Gov Crunchy Postgres chart with persistent storage and backups.
- Add service discovery, OIDC proxy authentication, readiness/startup/liveness
  probes, graceful termination, disruption budgets, horizontal scaling,
  anti-affinity, and restricted-v2-compatible security contexts to the chart
  templates.
- Add chart documentation and validation guidance for `helm lint`, `helm template`, and an OpenShift render/admission check.
- Keep the existing Azure Container Apps Terraform modules, `infra/stack/`, Azure Key Vault integration, Azure Container Registry flow, Python catalog-as-code package, and GitHub Actions deployment workflows unchanged.

## Capabilities

### New Capabilities

- `openshift-helm-deployment`: Deploy the complete GeoServer Cloud runtime and its PostgreSQL/PostGIS and RabbitMQ dependencies on OpenShift through a configurable, secure Helm release.

### Modified Capabilities

None.

## Impact

- **New infrastructure code:** `infra/helm/crunchy-postgres/` owns the vendored
  `bcgov/action-crunchy` templates at a documented commit. `infra/helm/geoserver-cloud/`
  owns the application workloads and accepts `database.crunchyReleaseName` as an
  input. The two charts have independent values, schemas, and install
  documentation; neither chart depends on an external Crunchy chart repository.
- **Terraform:** No Terraform modules or `infra/stack/` resources change. Azure Container Apps remains an independent deployment target.
- **Python:** No files in `geo-server-app-config/` change. Catalog reconciliation continues to target the deployed GeoServer endpoint through its existing environment configuration.
- **OpenShift resources:** The two releases add a Node OIDC proxy Deployment and
  Service, GeoServer Cloud and ACL Deployments and Services, a persistent RabbitMQ
  workload, the Crunchy Postgres chart resources for PostgreSQL/PostGIS, PVCs,
  Secret references, ConfigMaps, probes, PodDisruptionBudgets, HPAs, and an
  optional proxy Route. The gateway remains ClusterIP-only.
- **BC Gov platform compliance:** Chart templates must run under the namespace's `restricted-v2` SCC, use non-root arbitrary UIDs, drop all capabilities, disable privilege escalation, use a read-only root filesystem with explicit writable scratch volumes, set resource requests, avoid hard-coded UID/GID values, and follow the `openshift-deployment` guidance for controllers, probes, termination, PDBs, HPA behavior, anti-affinity, and topology spread. Container images must use the Platform Artifactory path and an approved image-pull Secret. NetworkPolicy, storage-class selection, registry onboarding, Vault integration, GitOps onboarding, and cluster administration remain platform-owned concerns unless added in a later change.
- **GitHub Actions and environments:** No GitHub Actions deployment jobs, Azure GitHub Environments, or new static credentials are added. CI/CD changes are out of scope; operators or an existing GitOps process install the chart.
- **Operations:** OpenShift operators must supply namespace, Artifactory access and pull Secret, approved image repository paths, storage class and quota, OIDC client registration, Crunchy Postgres backup repository settings, and backup/restore procedures before installing the chart.
