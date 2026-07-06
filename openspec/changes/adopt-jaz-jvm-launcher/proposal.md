## Why

GeoServer Cloud's 9 JVM-based microservices (gateway, webui, wms, wfs, wcs, wps, rest, gwc, acl) run today as unmodified upstream images, imported byte-for-byte into ACR via Terraform's `importImage` action (`infra/modules/registry/main.tf`) — there is no Dockerfile and no control over the JVM launch command anywhere in this repo. Every service starts with generic, non-container-aware `java -jar` defaults, which is a contributing factor to the slow (~4-6 minute) simultaneous-restart settling behavior already observed in dev and is part of why `min_replicas=1` had to be forced onto every OWS service as a (cost-negative) stopgap. Microsoft's `jaz` (Azure Command Launcher for Java, currently public preview) is a drop-in replacement for the `java` command that reads cgroup v1/v2 limits and applies tuned heap/GC/startup flags automatically. Adopting it requires layering it onto the pinned upstream images via custom Dockerfiles, since today those images are consumed exactly as published.

## What Changes

- Introduce a shared, parametrized Dockerfile that layers the `jaz` launcher onto each pinned upstream `geoservercloud/geoserver-cloud-<service>` / `geoservercloud/geoserver-acl` image and swaps the container entrypoint from `java` to `jaz` (drop-in — same JVM args, no application changes).
- Replace Terraform's straight `importImage` mirroring for these 9 images with an actual build step, following the existing `null_resource` + `az acr build` pattern already proven in this repo for `node-oidc-proxy` (server-side ACR build — no Docker daemon, works inside BC Gov ALZ network constraints). RabbitMQ and PostgreSQL are not JVM workloads and keep the current import path unchanged.
- Add a pinned `jaz` version as a new Terraform variable, following the same `TF_VAR_*` / GitHub Environment convention already used for `gs_cloud_version` and `acl_version`.
- Stage the rollout: pilot the Dockerfile + jaz on one low-traffic service first, verify the tuning actually engages and the service still starts and serves correctly, before switching the remaining 8 images from import to build. This is a production image-supply-chain change for every GeoServer Cloud service, so it is rolled out incrementally rather than all at once.
- Surface an explicit sign-off point before any non-pilot rollout: `jaz` sends usage telemetry to Microsoft by default, and no confirmed telemetry opt-out exists in current docs (only `JAZ_EXIT_WITHOUT_FLUSH`, which skips the flush delay but "might still send telemetry"). This needs a data-egress/privacy check against BC Gov ALZ policy before it runs in test/prod.

## Capabilities

### New Capabilities
- `custom-service-images`: GeoServer Cloud's JVM-based service images (gateway, webui, wms, wfs, wcs, wps, rest, gwc, acl) are produced by building a custom Dockerfile on top of the pinned upstream image, rather than importing the upstream image unmodified.
- `jvm-launcher-tuning`: Those custom images launch the JVM via the `jaz` Azure Command Launcher instead of `java`, so heap/GC/startup behavior is automatically tuned to the Container App's actual cgroup resource limits.

### Modified Capabilities
None — the existing `catalog` capability (GeoServer catalog-as-code reconciliation) is unaffected; this change does not alter GeoServer catalog behavior.

## Impact

**Terraform:**
- `infra/stack/locals.tf`: remove the 9 GeoServer Cloud/ACL entries from `registry_images` (rabbitmq/postgres imports stay); add a services-to-build local and per-image build trigger hashes (mirrors `null_resource.build_proxy_image`).
- `infra/stack/main.tf`: add `null_resource` build resources (one per service, `for_each`) running `az acr build` against the new Dockerfile; `module.service` / `module.acl` keep the same `image = "${module.registry.login_server}/${repo}:${tag}"` shape — only the upstream source of that tag changes, from imported to built.
- `infra/stack/variables.tf`: add `jaz_version` (new `TF_VAR_jaz_version`).
- `infra/modules/registry/`: unchanged (import mechanism stays live for rabbitmq/postgres).

**New files:** a shared, parametrized Dockerfile (exact path decided in design.md) plus any build-context files it needs.

**CI/CD:** `.github/workflows/terraform-deploy.yml` is unaffected structurally — the build stays inside `terraform apply` via `local-exec`, same as the proxy image today. GitHub Environment variables gain a `TF_GS_JAZ_VERSION`-style entry across dev/test/prod (per the header comment convention in `terraform-deploy.yml`).

**BC Gov ALZ compliance:** no networking, tagging, or OIDC changes. The one compliance-relevant item is `jaz`'s default telemetry egress to Microsoft, which needs a data-egress/privacy review given this stack already enforces no-public-endpoint / internal-only policies elsewhere.

**Carried into design.md as an open risk:** the upstream `geoserver-cloud` images may ship a JRE-only or custom `jlink` runtime rather than a full JDK; `jaz` requires a full JDK to apply its tuning and only launches "best effort" otherwise. This must be verified against the actual pulled image, not assumed, before the pilot.
