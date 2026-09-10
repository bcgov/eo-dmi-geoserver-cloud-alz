## 1. Terraform infrastructure boundary

- [x] 1.1 Compare `infra/stack/locals.tf`, `infra/deployment-config/`, and the pinned image variables with the Helm values contract for all eight GeoServer services, ACL, Crunchy Postgres, and RabbitMQ; record the Artifactory repository mapping for each image.
- [ ] 1.2 Verify that no files under `infra/modules/` or `infra/stack/` are changed by the Helm implementation and run the existing Azure Terraform validation or plan to confirm the Azure resource graph is unchanged.

## 2. Helm chart foundation

- [x] 2.1 Create separate `infra/helm/crunchy-postgres/` and `infra/helm/geoserver-cloud/` charts with standard Helm layouts and independent documentation.
- [x] 2.2 Vendor the reviewed `bcgov/action-crunchy` templates at commit `ab3db55f4d26e14f79fa89884f3ac2460109bd76`; remove external chart dependencies and the dependency lock file.
- [x] 2.3 Define schema-validated GeoServer values for Artifactory image repositories and immutable tags or digests, service ports and targets, replicas, resource requests with optional limits, probes, `database.crunchyReleaseName`, `database.crunchyUserName`, runtime Secret names, proxy OIDC settings, and optional proxy Route settings.
- [x] 2.4 Add chart helper templates for release naming, common labels, selector labels, service names, and consistent environment-specific metadata without creating or modifying the OpenShift namespace.

## 3. Node OIDC proxy and GeoServer Cloud workloads

- [x] 3.1 Add the hardened Node OIDC proxy Deployment, ClusterIP Service, health probes, HPA, PDB, Secret-backed OIDC/session configuration, and internal gateway origin.
- [x] 3.2 Add the optional proxy-only OpenShift Route and prevent direct gateway Route exposure.
- [x] 3.3 Render Deployments and ClusterIP Services for `gateway`, `webui`, `wms`, `wfs`, `wcs`, `wps`, `rest`, `gwc`, and `acl` from a single service map.
- [x] 3.4 Adapt the shared Spring deployment configuration into chart-managed ConfigMap data and configure Kubernetes Service DNS targets for the gateway and ACL connections.
- [x] 3.5 Add configurable actuator startup, liveness, and readiness probes, graceful termination, writable scratch volumes, restricted-v2 security contexts, pod anti-affinity, PDBs, and HPAs with explicit scale-up and scale-down behavior for stateless Deployments.

## 4. Stateful PostgreSQL/PostGIS and RabbitMQ resources

- [x] 4.1 Configure the standalone vendored Crunchy chart for approved PostgreSQL/PostGIS versions, HA instance replicas, per-instance storage and resources, pgBouncer Service discovery, and restricted-v2-compatible settings.
- [x] 4.2 Configure Crunchy pgBackRest repository storage, backup schedules, retention, restore settings, and approved Artifactory image paths; verify the required backup Secret is referenced without embedding values.
- [x] 4.3 Implement the RabbitMQ StatefulSet, stable Service, per-pod `volumeClaimTemplates`, pinned Artifactory image values, Secret-backed credentials, and internal-only broker configuration.
- [x] 4.4 Add stateful termination grace periods, ordered readiness, appropriate non-zero disruption budgets, explicit writable data mounts, and restricted-v2-compatible security contexts without hard-coded UID or GID values.
- [x] 4.5 Add a supported Crunchy initialization path or hardened namespaced Job that idempotently creates the `pgconfig` and `acl` schemas through the pgBouncer Service; do not define a competing PostgreSQL StatefulSet.
- [x] 4.6 Document the Crunchy HA profile, storage, pgBackRest backup and restore test, and the single-replica RabbitMQ decision before production installation.

## 5. Secret and image supply-chain contract

- [x] 5.1 Set every application and dependency image to an `artifacts.developer.gov.bc.ca` path, using the approved Artifactory remote repository for Docker Hub-origin images and `bcgov-docker-local` for Crunchy images; reject direct Docker Hub and floating `latest` references.
- [x] 5.2 Support the cluster-wide Artifactory remote-cache Secret or an `ArtifactoryServiceAccount`-generated `artifacts-*` Secret, attach it through `imagePullSecrets`, and document the required service-account Secret link.
- [x] 5.3 Create the `geoserver-cloud-runtime` Secret with stable generated values, accept an optional first-install OIDC client secret through `--set-string`, and wire all application passwords and usernames through `secretKeyRef`; retain Crunchy database and platform image-pull Secret ownership.
- [x] 5.4 Add a preflight values and operator procedure that checks required Secret names and keys, Artifactory repository paths, immutable image versions, Crunchy images, storage class, backup repository, and namespace quota before Helm installation.
- [x] 5.5 Add checks or documentation that prevent fixed credentials from being supplied through committed values files or Helm `--set` arguments, and document Helm release metadata access controls.

## 6. Python catalog-as-code boundary

- [x] 6.1 Confirm that `geo-server-app-config/` and existing catalog and ACL requirements need no code or schema changes for the OpenShift deployment.
- [ ] 6.2 After a development release is running, execute `geoserver-apply validate` and the existing catalog, ACL, rendering, and security integration checks through the OpenShift proxy endpoint.

## 7. GitHub Actions boundary

- [x] 7.1 Confirm that `.github/workflows/` receives no Helm deployment job, cluster credential, GitHub Environment, or static secret changes because release installation is operator- or GitOps-managed.
- [x] 7.2 Record the supported operator or existing GitOps handoff without adding cluster access to the current Azure Terraform workflows.

## 8. Validation, documentation, and rollout

- [x] 8.1 Document development, test, and production values examples without secret values, including Artifactory and vendored Crunchy prerequisites, template refresh guidance, `helm lint`, `helm template`, and the required OpenShift prerequisites.
- [x] 8.2 Run `helm lint` and render representative values for development, test, and production; verify the output contains the complete workload set, only approved Artifactory image paths, expected Service DNS targets, no unintended edge resources, and no embedded credentials.
- [ ] 8.3 Run `oc apply --dry-run=server -f -` on the separately rendered Crunchy and GeoServer manifests in the target namespace and resolve restricted-v2 SCC, quota, image-policy, dependency, and schema errors before installation.
- [ ] 8.4 Run `infra/helm/deploy-geoserver-cloud.sh` for the development release; verify the script waits for Crunchy primary/replica readiness, the release-derived user Secret, and pgBouncer before installing GeoServer, then verify proxy OIDC login, probes, pgBackRest behavior, RabbitMQ PVC attachment, internal gateway routing, ACL access, RabbitMQ events, PostGIS availability, and rendering behavior.
- [ ] 8.5 Test an application-only upgrade and `helm rollback` while preserving Crunchy Postgres and RabbitMQ persistent claims, then execute and document a pgBackRest backup and restore test for stateful version changes.
