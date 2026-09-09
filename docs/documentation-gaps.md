# Documentation Gap Register

**Project:** GeoServer Cloud on Azure Container Apps
**Audit date:** 2026-09-08
**Scope:** Whole repository
**Status:** Documentation follow-up completed on 2026-09-08; implementation
mismatches and operational follow-ups remain explicitly listed below.

## Purpose

This document records missing, stale, contradictory, or incomplete documentation
found in the repository. It covers infrastructure, deployment, security, the Node
OIDC proxy, catalog-as-code, testing, CI/CD, and operations.

This is a documentation backlog. It does not change application behavior. Where
the audit found a possible code or configuration defect, it is listed separately
as an implementation/documentation mismatch.

The follow-up added the guides linked from [README.md](../README.md), corrected
the proxy contract, expanded module references, and added the missing test,
catalog, CI/CD, troubleshooting, recovery, variable, and version documents.
The `IM-*` items remain decisions or code/configuration work and were not changed
by a documentation-only update.

## Audit Method

The audit compared prose with the current implementation in:

- [README.md](../README.md)
- [AGENTS.md](../AGENTS.md)
- [docs/architecture.md](architecture.md)
- [docs/runbook.md](runbook.md)
- [docs/node-oidc-proxy-contract.md](node-oidc-proxy-contract.md)
- [node-oidc-proxy/](../node-oidc-proxy/)
- [infra/](../infra/)
- [geo-server-app-config/](../geo-server-app-config/)
- [integration-tests/](../integration-tests/)
- [.github/workflows/](../.github/workflows/)
- [openspec/](../openspec/)
- [mise.toml](../mise.toml)

Runtime code, Terraform, workflow definitions, and tests were treated as the
current behavior. Prose was marked stale when it disagreed with those sources.

## Priority Definitions

| Priority | Meaning |
| --- | --- |
| P0 | A security or deployment contract is wrong. Correct the documentation before relying on it. |
| P1 | An operator cannot deploy, operate, recover, or extend the system safely without reading source code. |
| P2 | The information exists only in scattered comments, is hard to find, or is incomplete for maintenance. |
| P3 | Useful reference or process documentation is missing, but the gap is unlikely to block normal operation. |

## Summary

The repository has useful component comments, but it does not yet have one
operator-facing documentation set. The highest-risk gaps are:

1. The OIDC contract documents the wrong principal claim.
2. The OIDC contract says roles are not sent in a header, but the proxy sends
   `sec-roles` and GeoServer uses it.
3. The contract refers to JDBC role services, but the security script removes
   JDBC services and uses the built-in XML service.
4. The trust boundary between the public proxy, internal gateway, and
   `SharedAuth` filter is not documented.
5. There is no complete guide for local setup, integration tests, catalog
   reconciliation, rollback, disaster recovery, or troubleshooting.

## P0: Correct Security and Deployment Contracts

### DG-001: OIDC principal claim is documented incorrectly

**Type:** Contradictory documentation

**Evidence:**

- [docs/node-oidc-proxy-contract.md](node-oidc-proxy-contract.md) describes
  `idir_user_guid` as the value injected into `sec-username`.
- [infra/stack/main.tf](../infra/stack/main.tf) sets `USERNAME_CLAIM` to
  `email` and `USERNAME_LOWERCASE` to `true`.
- [node-oidc-proxy/src/oidc.ts](../node-oidc-proxy/src/oidc.ts) extracts the
  configured claim and uses it as the principal.
- [node-oidc-proxy/src/config.ts](../node-oidc-proxy/src/config.ts) stores the
  GUID as a separate audit/reference claim.

**Impact:** An operator can configure Keycloak and GeoServer role data for a GUID
while the deployed system authenticates users by lower-case email. An email
change also changes the effective GeoServer principal.

**Required documentation:** State the deployed behavior first: `email` becomes
`sec-username`, lower-cased by the current Terraform setting. Explain that
`idir_user_guid` is retained separately. Document the consequences of changing
`USERNAME_CLAIM` and the required GeoServer role and user migration.

**Owner:** Proxy and security documentation.

### DG-002: Role transport is documented incorrectly

**Type:** Contradictory documentation

**Evidence:**

- [docs/node-oidc-proxy-contract.md](node-oidc-proxy-contract.md) says roles are
  not sent as a header and are resolved by a role service.
- [node-oidc-proxy/src/proxy.ts](../node-oidc-proxy/src/proxy.ts) injects the
  configured roles header for every authenticated session.
- [infra/stack/main.tf](../infra/stack/main.tf) sets `GS_ROLES_HEADER=sec-roles`
  and `OIDC_ROLES=ROLE_ADMINISTRATOR`.
- [infra/scripts/configure-geoserver-security.sh](../infra/scripts/configure-geoserver-security.sh)
  configures `roleSource=Header` and `rolesHeaderAttribute=sec-roles`.

**Impact:** The current deployment gives every OIDC-authenticated session the
same configured role set. The contract suggests per-user role lookup, which is
not the active behavior.

**Required documentation:** Describe the `sec-username` and `sec-roles` header
contract, the fact that inbound identity headers are stripped, the current
`ROLE_ADMINISTRATOR` setting, and the boundary between authentication and
fine-grained `geoserver-acl` authorization.

**Owner:** Proxy and GeoServer security documentation.

### DG-003: JDBC role-service documentation is stale

**Type:** Contradictory documentation

**Evidence:**

- [docs/node-oidc-proxy-contract.md](node-oidc-proxy-contract.md) says the
  Terraform side provides a JDBC role service backed by PostgreSQL.
- [infra/scripts/configure-geoserver-security.sh](../infra/scripts/configure-geoserver-security.sh)
  removes the JDBC security files because the GeoServer Cloud 3.0 deployment
  cannot load them reliably.
- The active script uses the built-in `default` XML role and user/group services.

**Impact:** Operators can follow the contract and create a security service that
the deployment deliberately removes.

**Required documentation:** State that the active service is the built-in XML
service and explain where role assignment is performed. Mark the old JDBC design
as rejected or historical, not as a deployment requirement.

**Owner:** GeoServer security and architecture documentation.

### DG-004: Proxy, gateway, and GeoServer trust boundaries are incomplete

**Type:** Missing security documentation

**Evidence:**

- [docs/architecture.md](architecture.md) states that the gateway is reachable
  through the internal load balancer.
- [infra/stack/locals.tf](../infra/stack/locals.tf) makes the gateway the only
  externally enabled Container App and keeps the OWS services internal.
- [infra/deployment-config/gateway.yml](../infra/deployment-config/gateway.yml)
  applies `SharedAuth` to gateway routes.
- The proxy strips and injects identity headers in
  [node-oidc-proxy/src/proxy.ts](../node-oidc-proxy/src/proxy.ts).

**Gap:** No document states which callers may reach the gateway directly, what
`SharedAuth` validates, whether a direct internal caller can submit identity
headers, or which network control prevents header spoofing outside the proxy.

**Impact:** A reader cannot determine whether the proxy is the only authentication
boundary or whether the internal gateway is independently safe from untrusted
callers.

**Required documentation:** Add a trust-boundary diagram and a direct-access
test or statement. Document gateway ingress, App Service VNet integration, ACA
internal DNS, `SharedAuth`, header stripping, and the controls required if other
VNet callers can reach the gateway.

**Owner:** Architecture, network, and security documentation.

### DG-005: Machine-authentication passthrough needs a security contract

**Type:** Incomplete security documentation

**Evidence:**

- [node-oidc-proxy/src/config.ts](../node-oidc-proxy/src/config.ts) defaults
  `MACHINE_AUTH_PASSTHROUGH` to `false`.
- [infra/stack/main.tf](../infra/stack/main.tf) sets it to `true` in the
  deployed App Service.
- [node-oidc-proxy/src/app.ts](../node-oidc-proxy/src/app.ts) forwards requests
  with Basic authentication or an `authkey` query parameter without injecting
  `sec-username`.
- [infra/scripts/configure-geoserver-security.sh](../infra/scripts/configure-geoserver-security.sh)
  wires `authKey` only into the OWS and tile-cache chains.

**Gap:** The documentation does not clearly explain the deployment override, the
security consequence, the exact supported paths, or the difference between Basic
authentication and `authkey`.

**Required documentation:** Document the default and deployment value, the
allowed paths, the fact that `authkey` does not authenticate the web UI or REST
configuration API, and the GeoServer validation responsibility.

**Owner:** Proxy and machine-client documentation.

## P1: Missing Operator Documentation

### DG-006: No complete proxy configuration reference exists

**Type:** Missing reference documentation

**Evidence:**

- [node-oidc-proxy/README.md](../node-oidc-proxy/README.md) lists only a subset
  of required settings.
- The complete defaults and validation rules are in
  [node-oidc-proxy/src/config.ts](../node-oidc-proxy/src/config.ts).
- The README instructs the user to copy `.env.example`, but no `.env.example`
  file exists.

**Required documentation:** Create a table for every proxy environment variable,
including type, default, required status, secret source, downstream consumer,
and production value. Include local `.env` setup, Keycloak redirect URI setup,
the separate `gs_sso` and `JSESSIONID` session roles, the 30-second refresh
threshold, the approximately 4 KB cookie limit, the `session:seal-large`
warning, timeouts, log settings, and the required claim names. State clearly
that `DEBUG_UNSAFE_HEADERS` must remain false because it can expose credentials
and session data.

### DG-007: Keycloak client and protocol mapper setup is incomplete

**Type:** Missing deployment documentation

**Evidence:**

- [docs/node-oidc-proxy-contract.md](node-oidc-proxy-contract.md) says to confirm
  claims but does not give a verification procedure.
- [node-oidc-proxy/src/oidc.ts](../node-oidc-proxy/src/oidc.ts) fails login when
  the configured principal claim is absent and logs the claim names.

**Required documentation:** Document the exact client redirect URI, post-logout
URI, web origin, client authentication type, required `email` claim, optional
`idir_user_guid` and `display_name` claims, and how to diagnose
`oidc:principal-claim-missing` and `oidc:callback-claims`.

### DG-008: GeoServer security bootstrap and recovery are not documented

**Type:** Missing operational documentation

**Evidence:**

- [infra/scripts/configure-geoserver-security.sh](../infra/scripts/configure-geoserver-security.sh)
  creates filters, modifies filter chains, bootstraps an administrator, creates
  machine users, and may restart OWS services.
- [infra/stack/main.tf](../infra/stack/main.tf) invokes the script as part of
  Terraform deployment.

**Gap:** The runbook does not explain prerequisites, inputs, safe re-run behavior,
failure recovery, admin bootstrap, or the effect of restarting OWS replicas.

**Required documentation:** Add a security bootstrap runbook with required
environment variables, Key Vault dependencies, SOCKS5 requirements, verification
commands, admin recovery, and machine-key propagation behavior.

### DG-009: Machine-client lifecycle documentation is incomplete

**Type:** Missing operational documentation

**Evidence:**

- [geo-server-app-config/README.md](../geo-server-app-config/README.md) documents
  decommissioning but not the full provisioning and rotation workflow.
- [infra/stack/variables.tf](../infra/stack/variables.tf) defines the
  `machine_client_usernames` input.
- [infra/stack/main.tf](../infra/stack/main.tf) creates one Key Vault secret per
  username.

**Required documentation:** Explain how to add a client, apply Terraform, run
  security configuration, obtain the Key Vault secret, add the username-scoped
  ACL rule, test OWS access, rotate a key, revoke a leaked key, and remove the
  identity from all three systems.

### DG-010: Catalog YAML schema is not documented for users

**Type:** Missing reference documentation

**Evidence:**

- [geo-server-app-config/geoserver_catalog_schema.py](../geo-server-app-config/geoserver_catalog_schema.py)
  defines the complete Pydantic model.
- [geo-server-app-config/README.md](../geo-server-app-config/README.md) gives a
  directory listing but not a field reference.

**Required documentation:** Add examples and field tables for workspaces, stores,
  feature types, layer groups, styles, and ACL rules. Include defaults such as
  `EPSG:3005`, valid layer-group modes, required references, and style-name rules.

### DG-011: Environment YAML and secret resolution rules are incomplete

**Type:** Missing reference documentation

**Evidence:**

- [geo-server-app-config/environments/](../geo-server-app-config/environments/)
  contains dev, test, and prod files.
- [geo-server-app-config/geoserver_apply.py](../geo-server-app-config/geoserver_apply.py)
  resolves `kv://` with `DefaultAzureCredential` and `tf://` through Terraform
  outputs.

**Required documentation:** Explain the environment-file schema, how environment
  names map to Terraform state, required Azure permissions, credential lookup
  order, how to add an environment, and which values must be unique per
  environment.

### DG-012: Reconciliation behavior and failure recovery are incomplete

**Type:** Missing operational documentation

**Evidence:**

- [geo-server-app-config/reconcile.py](../geo-server-app-config/reconcile.py)
  validates references, waits for GeoServer, applies resources in a fixed order,
  prints a summary, and raises after errors.
- The current README shows only the `validate`, `--dry-run`, and apply commands.

**Required documentation:** Describe validation, secret resolution, health polling,
  apply order, idempotency, partial failure behavior, retry behavior, ACL skip
  behavior when no ACL configuration exists, and how to retry or repair a partial
  apply. State clearly that this is not a transactional rollback.

### DG-013: ACL semantics are fragmented

**Type:** Incomplete reference documentation

**Evidence:**

- [geo-server-app-config/README.md](../geo-server-app-config/README.md) contains
  important priority and `service`/`request` rules.
- More design detail is only in
  [openspec/changes/scope-machine-client-authkeys/design.md](../openspec/changes/scope-machine-client-authkeys/design.md).
- The wire mapping is implemented in
  [geo-server-app-config/geoserver_client.py](../geo-server-app-config/geoserver_client.py).

**Required documentation:** Create one stable ACL reference covering role versus
  username, priority ordering, wildcard layers, `READ`/`WRITE`/`ADMIN` mapping,
  `DENY`, OWS service/request matching, and tests for read, write, and denial.

### DG-014: Integration-test setup and purpose are not documented

**Type:** Missing test documentation

**Evidence:**

- [integration-tests/](../integration-tests/) has proxy, OWS, catalog, rendering,
  and security tests but no README.
- [integration-tests/conftest.py](../integration-tests/conftest.py) requires a
  Bastion SOCKS5 tunnel and can read Terraform outputs and Key Vault secrets.
- The tests are not invoked by the current GitHub Actions workflows.

**Required documentation:** Add prerequisites, Bastion tunnel setup, required
  environment variables, environment safety rules, test order, fixture behavior,
  expected catalog data, commands for one test file versus the full suite, and
  failure diagnosis. State whether integration tests are a release gate or a
  manual validation step.

### DG-015: Local development setup is spread across scripts

**Type:** Missing onboarding documentation

**Evidence:**

- [README.md](../README.md) has a short quick start.
- [local-run.sh](../local-run.sh) contains the detailed Bastion, Windows Git Bash,
  Azure login, proxy, state, and catalog bootstrap behavior.
- [mise.toml](../mise.toml) is the version source but does not explain setup or
  upgrades.

**Required documentation:** Add a local development guide with Windows/Git Bash
  prerequisites, `mise install`, Azure login, Bastion tunnel setup, state backend
  variables, `local-run.sh` commands, catalog bootstrap, log access, and cleanup.

### DG-016: CI/CD workflow and environment protection guide is missing

**Type:** Missing operational documentation

**Evidence:**

- [ci.yml](../.github/workflows/ci.yml) runs checks and a tools-environment plan.
- [cd-dev.yml](../.github/workflows/cd-dev.yml) applies on merge to main.
- [cd-test.yml](../.github/workflows/cd-test.yml) and
  [cd-prod.yml](../.github/workflows/cd-prod.yml) use manual dispatch.
- [terraform-deploy.yml](../.github/workflows/terraform-deploy.yml) defines
  permissions, environment variables, plan artifacts, and catalog apply.

**Required documentation:** Add a workflow diagram and a table of triggers,
  environments, approvals, GitHub Variables, OIDC subjects, state keys, plan
  artifact behavior, required checks, and failure/retry actions. State that
  integration tests are not currently part of these workflows.

### DG-017: Post-deployment validation is not a documented procedure

**Type:** Missing operational documentation

**Evidence:** [docs/runbook.md](runbook.md) describes deployment but does not
  provide a complete validation sequence.

**Required documentation:** Define checks for proxy `/healthz`, OIDC redirect,
  gateway routing, GeoServer REST authentication, OWS anonymous denial,
  authenticated OWS access, machine `authkey` access, ACL enforcement, RabbitMQ,
  PostgreSQL, Key Vault, and catalog reconciliation.

### DG-018: Rollback and disaster recovery procedures are missing

**Type:** Missing operational documentation

**Evidence:** There is no dedicated rollback or disaster-recovery document.
  [docs/runbook.md](runbook.md) contains teardown guidance but no restore process.

**Required documentation:** Define RTO/RPO targets, PostgreSQL backup and restore,
  pgconfig catalog recovery, PostGIS recovery, Key Vault recovery, RabbitMQ data
  recovery, image rollback, Terraform partial-apply recovery, catalog rollback,
  and the required approval path for destructive actions.

### DG-019: Secret lifecycle and rotation procedures are missing

**Type:** Missing security operations documentation

**Evidence:** Secrets are generated or read by [infra/stack/main.tf](../infra/stack/main.tf),
  but the repository does not provide a rotation schedule or procedure. Several
  Terraform resources intentionally ignore password changes.

**Required documentation:** Document ownership, expiry, rotation, emergency
  revocation, dependency restart requirements, Key Vault version behavior, and
  validation after rotating PostgreSQL, ACR, RabbitMQ, ACL, GeoServer admin, OIDC,
  and proxy-session secrets.

### DG-020: Network and private-endpoint preflight checks are missing

**Type:** Missing deployment documentation

**Evidence:** [docs/runbook.md](runbook.md) lists required subnets, but does not
  give commands to verify delegation, DNS zones, route reachability, or private
  endpoint resolution before apply.

**Required documentation:** Add checks for ACA subnet delegation and size, App
  Service integration subnet, private endpoint subnet, private DNS links, Key
  Vault/PostgreSQL resolution, gateway reachability, and the Bastion tunnel.

## P2: Scattered or Incomplete Reference Documentation

### DG-021: GeoServer Cloud configuration reference is missing

**Evidence:** Environment variables are distributed across
[infra/stack/locals.tf](../infra/stack/locals.tf),
[infra/deployment-config/geoserver.yml](../infra/deployment-config/geoserver.yml),
and the gateway YAML files.

**Gap:** There is no map from each variable to the service, Spring profile,
secret, default, or operational effect. WPS intentionally disables ACL, but this
choice is not explained in an operator document.

**Required documentation:** Create a GeoServer Cloud configuration reference for
profiles, service routes, ports, shared environment variables, ACL settings,
pgconfig, RabbitMQ, admin credentials, and per-service exceptions.

### DG-022: pgconfig and initialization behavior are under-documented

**Evidence:** [infra/stack/main.tf](../infra/stack/main.tf) creates database
initialization jobs and exposes `reset_pgconfig_schema`; architecture documentation
only names pgconfig.

**Required documentation:** Explain the databases and schemas, initialization
order, reset behavior and destructive effect, PostGIS initialization, catalog
ownership, inspection queries, backup boundaries, and recovery after a failed job.

### DG-023: Deployment-config publication is not documented

**Evidence:** [infra/deployment-config/README.md](../infra/deployment-config/README.md)
only says that the files are mounted. [infra/stack/rabbitmq-storage.tf](../infra/stack/rabbitmq-storage.tf)
publishes them to an Azure File share during apply.

**Required documentation:** List every config file, its consumers, the upload
  trigger, mount path, read-only behavior, update and rollback procedure, and
  how to verify that a running service loaded a new version.

### DG-024: Sticky sessions and GeoWebCache storage need a single operational note

**Evidence:** [infra/stack/main.tf](../infra/stack/main.tf) patches sticky sessions
with `azapi_update_resource`; [docs/runbook.md](runbook.md) says GeoWebCache uses
ephemeral storage but gives no setup procedure.

**Required documentation:** Explain Wicket session affinity, why the provider
workaround exists, the removal condition, GeoWebCache cache durability choices,
Azure Files configuration, cache loss behavior, and scale-out limitations.

### DG-025: RabbitMQ durability and production hardening are not consolidated

**Evidence:** [infra/stack/rabbitmq-storage.tf](../infra/stack/rabbitmq-storage.tf)
uses a public Standard storage account for the proof-of-concept and contains a
production private-endpoint TODO. RabbitMQ requires a warm replica because its
ingress has no scale trigger.

**Required documentation:** Explain queue durability, replica requirements,
storage failure behavior, public-network risk, private-endpoint migration, and
how catalog event loss is detected and repaired.

### DG-026: Network module and observability reference are incomplete

**Evidence:** [infra/modules/network/](../infra/modules/network/) has no README.
[infra/modules/observability/README.md](../infra/modules/observability/README.md)
exists but only gives a one-paragraph summary.

**Required documentation:** Add a network module README with input/output and
ownership details for VNet data sources, subnets, NSGs, private DNS, and the
locked networking resource group. Expand the observability README with Log
Analytics retention, workspace sizing, outputs, metrics, alerts, and alert
ownership.

### DG-027: Terraform variable reference is missing

**Evidence:** [infra/stack/variables.tf](../infra/stack/variables.tf) is the only
complete variable list.

**Required documentation:** Add a reference that separates required and optional
inputs, environment-specific values, secrets, naming constraints, cost-sensitive
settings, destructive flags, and variables that must match catalog or image
configuration.

### DG-028: Version compatibility and upgrade policy are missing

**Evidence:** [mise.toml](../mise.toml) pins Terraform, Node, Python, TFLint, uv,
Checkov, and the Azure ruleset. Terraform variables pin GeoServer Cloud, ACL, and
RabbitMQ image versions. No compatibility matrix exists.

**Required documentation:** Record tested combinations, upgrade order, rollback
strategy, required validation, image extension compatibility, and how to update
tool pins in `mise.toml`.

### DG-029: Troubleshooting guide is missing

**Evidence:** Troubleshooting instructions are distributed through inline comments
in [local-run.sh](../local-run.sh), [infra/scripts/tf.sh](../infra/scripts/tf.sh),
and [configure-geoserver-security.sh](../infra/scripts/configure-geoserver-security.sh).

**Required documentation:** Add symptom-based guidance for expired Azure login,
missing SOCKS5 tunnel, private DNS failure, ACR image pull failure, Terraform
state lock, failed init job, gateway 502, proxy 401, OIDC claim failure,
GeoServer 401, ACL denial, stale authkey replicas, and catalog partial failure.

### DG-030: Monitoring and alerting guidance is missing

**Evidence:** The project creates Log Analytics and configures application logs,
but no document defines dashboards, queries, alert thresholds, retention, or
on-call actions.

**Required documentation:** Define health signals and alerts for proxy availability,
OIDC failures, gateway 502 responses, GeoServer startup, ACL latency/errors,
RabbitMQ queue health, PostgreSQL health, private endpoint DNS, Container App
restarts, and Key Vault access failures.

### DG-031: Security hardening checklist is incomplete

**Evidence:** [docs/runbook.md](runbook.md) mentions Key Vault network access,
GeoWebCache, PostgreSQL HA, and gateway validation. [SECURITY_ANALYSIS-local.md](../SECURITY_ANALYSIS-local.md)
lists additional risks, including unsafe debug logging, TLS verification bypass,
credential rotation, and ACR admin credentials.

**Required documentation:** Integrate the security findings into a production
readiness checklist with owners, required values, validation commands, and the
bootstrap-to-hardened transition. Do not leave the local security analysis as the
only place where these risks are recorded.

### DG-032: `tools` environment is not explained consistently

**Evidence:** [infra/scripts/tf.sh](../infra/scripts/tf.sh) accepts `tools`;
[local-run.sh](../local-run.sh) uses it; [ci.yml](../.github/workflows/ci.yml)
plans against it. Other runbook sections list only dev, test, and prod.

**Required documentation:** Define the purpose, state key, resource ownership,
allowed operations, cleanup policy, and differences between `tools` and deployed
runtime environments.

### DG-033: OpenSpec documentation ownership is not clear

**Evidence:** [AGENTS.md](../AGENTS.md) says OpenSpec artifacts are the project
workflow, while change folders contain both historical and active design details.

**Required documentation:** State which artifacts are authoritative after a change
is archived, how implementation changes sync back to specs, and which operational
facts must also be copied into `docs/`. Link stable operational docs from the
relevant OpenSpec changes.

### DG-034: Documentation link validation is not automated

**Evidence:** The `docs/anti-patterns.md` reference from
[geo-server-app-config/geoserver_apply.py](../geo-server-app-config/geoserver_apply.py)
now resolves, but no CI job checks Markdown links or references in source
comments.

**Required documentation:** Document the link-check requirement and add a link
validation job when the CI workflow is changed.

### DG-035: Documentation-only changes are excluded from CI/CD triggers

**Evidence:** [ci.yml](../.github/workflows/ci.yml) and [cd-dev.yml](../.github/workflows/cd-dev.yml)
use `paths-ignore` for Markdown and `docs/**`.

**Gap:** There is no documentation policy that states whether docs are validated
separately, why docs-only changes skip CI, or how broken links are detected.

**Required documentation:** Define the documentation validation path. At minimum,
run a Markdown link check or a lightweight documentation job when documentation
files change.

## P3: Useful Reference Gaps

### DG-036: No contribution and change-management guide

There is no `CONTRIBUTING.md` that explains branch naming, Conventional Commit
requirements, OpenSpec proposal flow, review expectations, tests, and deployment
approval rules. The information is split across [AGENTS.md](../AGENTS.md),
workflow comments, and OpenSpec skills.

### DG-037: No changelog or migration history

There is no `CHANGELOG.md` describing image upgrades, Terraform/provider changes,
security behavior changes, breaking variable changes, or catalog migrations. This
is important because changes such as `machine_client_username` to
`machine_client_usernames` affect deployment inputs.

### DG-038: No cost and capacity guide

The repository defines CPU, memory, replica, PostgreSQL, storage, and App Service
settings, but does not describe their cost and performance effects. Document
minimum replicas, scale-to-zero risks, workload profiles, storage tiers, and
production sizing assumptions.

### DG-039: No API and route reference

The proxy contract lists proxy routes, but there is no single route matrix for
the public proxy, gateway routes, OWS services, REST, ACL, health checks, and
machine-auth paths. Document path preservation, base paths, authentication mode,
expected status behavior, and upstream service ownership.

### DG-040: No native-GeoServer-authentication decision record

The repository does not explain why it uses the Node OIDC proxy plus GeoServer
header authentication instead of GeoServer's OIDC extension. This is a key
architecture decision. Document the evaluated alternatives, version and plugin
compatibility, browser session behavior, machine-client requirements, internal
gateway boundary, and the conditions under which native GeoServer OIDC could
replace the proxy.

## Implementation and Documentation Mismatches

These items need a code/configuration decision as well as documentation. They
should not be silently solved by changing prose.

| ID | Finding | Evidence | Required decision |
| --- | --- | --- | --- |
| IM-001 | The reusable workflow comments list optional GitHub Variables, but the visible `env` block maps only the required variables. | [terraform-deploy.yml](../.github/workflows/terraform-deploy.yml) | Map the optional values to `TF_VAR_*`, or remove them from the supported-variable documentation. |
| IM-002 | The workflow contract comments say `dev/test/prod`, but the CI plan uses `tools` and `tf.sh` accepts four environments. | [terraform-deploy.yml](../.github/workflows/terraform-deploy.yml), [ci.yml](../.github/workflows/ci.yml), [tf.sh](../infra/scripts/tf.sh) | Document `tools` as a supported planning environment or remove the inconsistency. |
| IM-003 | Integration tests exist but are not called by the GitHub Actions workflows. | [integration-tests/](../integration-tests/), [.github/workflows/](../.github/workflows/) | Decide whether they are manual, scheduled, or release-gating tests, then document and implement that choice. |
| IM-004 | The security contract and active configuration disagree about GUID versus email, role headers, and JDBC versus XML roles. | [docs/node-oidc-proxy-contract.md](node-oidc-proxy-contract.md), [main.tf](../infra/stack/main.tf), [configure-geoserver-security.sh](../infra/scripts/configure-geoserver-security.sh) | Update the contract to current behavior or change the implementation and test it. |
| IM-005 | The `docs/anti-patterns.md` reference is now resolved, but documentation links are not checked automatically. | [geoserver_apply.py](../geo-server-app-config/geoserver_apply.py), [ci-cd.md](ci-cd.md) | Add a Markdown and source-reference link check to CI. |
| IM-006 | The environment files contain `http.retries`, while the reconciliation path uses the client retry decorators and does not visibly consume that setting. | [environments/dev.yaml](../geo-server-app-config/environments/dev.yaml), [geoserver_client.py](../geo-server-app-config/geoserver_client.py) | Decide whether the setting is supported. Document it only if it is active. |
| IM-007 | Some production-hardening requirements remain code TODOs, including public RabbitMQ storage access and private endpoint work. | [rabbitmq-storage.tf](../infra/stack/rabbitmq-storage.tf) | Track the hardening work and document the current proof-of-concept risk. |

## Recommended Documentation Backlog

Create or update these documents in this order:

1. Completed: updated [docs/node-oidc-proxy-contract.md](node-oidc-proxy-contract.md)
  for DG-001 through DG-005.
2. Completed: created `docs/security-and-identity.md`.
3. Completed: created `docs/operations-guide.md`.
4. Completed: created `docs/catalog-reference.md` and
  `docs/geoserver-configuration.md`.
5. Completed: created `integration-tests/README.md`.
6. Completed: created `docs/ci-cd.md`.
7. Completed: created `docs/troubleshooting.md` and `docs/disaster-recovery.md`.
8. Completed: added `infra/modules/network/README.md` and expanded
  `infra/modules/observability/README.md`.
9. Completed: added `CONTRIBUTING.md`, `CHANGELOG.md`,
  `docs/version-compatibility.md`, `docs/monitoring.md`, and
  `docs/cost-and-capacity.md`.
10. Remaining: add automated documentation link validation to CI and resolve the
   implementation/documentation mismatches in the `IM-*` table.

## Definition of Done for the Documentation Follow-up

The documentation work is complete when:

- The proxy contract matches the deployed identity and role behavior.
- Every required secret, claim, redirect URI, and environment variable has one
  documented source and owner.
- A new operator can deploy, validate, troubleshoot, and recover the stack without
  reading Terraform or application source code.
- A new catalog maintainer can add a workspace, store, layer, style, group, or ACL
  rule from documented examples.
- Integration tests can be run from a clean workstation using a documented setup.
- The status of integration tests in CI/CD is explicit.
- Backup, restore, secret rotation, machine-client revocation, and rollback steps
  are tested or clearly marked as untested.
- Markdown links and important command examples are checked in CI.
