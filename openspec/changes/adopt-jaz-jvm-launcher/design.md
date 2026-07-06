## Context

Today, all 9 JVM-based GeoServer Cloud services (gateway, webui, wms, wfs, wcs, wps, rest, gwc, acl) are populated into ACR by `azapi_resource_action.import` (`infra/modules/registry/main.tf`) — a server-side `importImage` call that mirrors the upstream `geoservercloud/*` Docker Hub image byte-for-byte. There is no Dockerfile and no build step anywhere in this repo for these images; we do not control the JVM launch command at all.

This repo already has one proven pattern for building and pushing a custom image inside this ALZ environment: `node-oidc-proxy/Dockerfile` + `null_resource.build_proxy_image` in `infra/stack/main.tf`, which runs `az acr build` (server-side ACR Tasks build — no Docker daemon, no VNet access needed from the runner) and is hash-triggered on the Dockerfile/src/package.json contents. ACR is Standard SKU with `public_network_access_enabled = true` specifically so `az acr build` works without a private endpoint.

`jaz` (Azure Command Launcher for Java, public preview) is a drop-in replacement for the `java` command: `CMD ["jaz", "-jar", "app.jar"]` instead of `CMD ["java", "-jar", "app.jar"]`. It reads `/sys/fs/cgroup` to detect container memory/CPU limits and applies tuned heap/GC/startup flags, requires a full certified JDK (Temurin or Microsoft Build of OpenJDK 8/11/17/21/25 get full tuning; other OpenJDK-based JDKs still launch but without the full adjustment set; JRE-only/jlink runtimes are explicitly not fully supported), is configured entirely through environment variables (no CLI flags of its own), and sends usage telemetry to Microsoft by default. We do not own or build the upstream `geoserver-cloud` Maven project — the only integration point available to us is layering on top of its published images.

## Goals / Non-Goals

**Goals:**
- Every JVM-based GeoServer Cloud service launches its JVM through `jaz` instead of `java`, inheriting cgroup-aware tuning, with no change to any already-wired application config (Spring profiles, ACL, security, env vars).
- Image production for these 9 services moves from Terraform-side import to Terraform-side build, reusing the existing `az acr build` + `null_resource` hash-trigger pattern — no new CI system, no Docker daemon dependency, no change to how Container Apps reference images (`${login_server}/${repo}:${tag}`).
- Roll out incrementally (pilot → remaining services) so a bad interaction between `jaz` and an upstream image can't take down all 9 services in one apply.

**Non-Goals:**
- Not building the upstream GeoServer Cloud Maven project ourselves — we only add a layer on top of its published images.
- Not changing GeoServer application behavior, Spring profiles, security config, or ACL rules — `jaz` only changes how the JVM process is launched.
- Not solving the existing `min_replicas=1` cost stopgap in this change — that is a possible follow-up once jaz's effect on startup time is measured (see Open Questions).
- Not mirroring the Microsoft package repository — the Dockerfile adds it directly, the same trust boundary as pulling base images from Docker Hub/MCR today.

## Decisions

**1. One shared, parametrized Dockerfile, not one per service.**
A single `infra/docker/geoserver-cloud-jaz/Dockerfile` takes `ARG BASE_IMAGE` and is built once per service via a Terraform `for_each` build matrix, rather than 9 near-identical files. All 9 upstream images need the identical treatment (install `jaz`, swap the entrypoint) — only the base image reference differs. One file means one place to fix if the install steps change; 9 files would drift.
*Alternative considered:* per-service Dockerfiles under `infra/docker/<service>/Dockerfile` — rejected as duplication with no current per-service customization need. A future service-specific need (e.g. different `JAZ_*` env vars) is a Terraform env-var concern, not a reason to fork the Dockerfile.

**2. Build via the existing `null_resource` + `az acr build` pattern, not a separate CI stage.**
Reuses the proven, ALZ-compatible path already in `infra/stack/main.tf` (`null_resource.build_proxy_image`). Server-side ACR build needs no Docker daemon and no VNet access from the runner; the registry is already provisioned for exactly this (Standard SKU, public network access enabled). Keeping the build inside Terraform means the existing `depends_on` graph already guarantees images exist before a Container App tries to pull them, with no second build system to authenticate or trigger separately.
*Alternative considered:* a build-and-push job in `.github/workflows/terraform-deploy.yml` ahead of `plan` — rejected for this change; it would duplicate ACR auth wiring Terraform already has and decouple "does the image exist" from Terraform's own dependency graph. Worth revisiting if build time starts dominating `terraform apply` (see Risks).

**3. Scope: all 9 JVM services, not a subset.**
`gateway` (Spring Cloud Gateway/WebMVC) and `acl` (`geoserver-acl`) are JVM apps exactly like the 7 OWS services, so `jaz`'s tuning applies equally. Excluding them would leave the routing and authorization hot path untuned while backends are tuned — an arbitrary split. RabbitMQ (Erlang) and PostgreSQL (C) are not JVM workloads and are explicitly out of scope; they keep the current `importImage` path.

**4. Rollout order: pilot one service, `wps`, before the other 8.**
This system has already had multiple JVM-startup-adjacent production incidents (RabbitMQ Erlang-cookie crash loop, 4-6 minute multi-service settling after simultaneous restarts, cold-start 502s). Introducing a public-preview launcher across all 9 services in a single apply would widen exactly the blast radius this project has been working to narrow. `wps` is the pilot candidate: lowest request volume of the OWS set, and `ACL_ENABLED=false` is already set for it (`infra/stack/locals.tf`), so a pilot failure carries no authorization-path entanglement.
*Alternative considered:* piloting on `gateway` (highest-value target as the single entry point) — rejected specifically because it is the single entry point; a `jaz`-related startup failure there takes down the whole stack.

**5. `jaz` version pinned as a Terraform variable (`var.jaz_version`), not a `mise.toml` entry.**
`mise.toml` pins tools that run on the GitHub Actions runner or a developer's machine (terraform, node, python, tflint, uv). `jaz` never runs there — only inside the built container images. It belongs alongside `gs_cloud_version` and `acl_version`, which already version-pin container image content, not alongside `mise.toml`'s runner-tool pins.

## Risks / Trade-offs

- **[Risk — CONFIRMED, elevated] The certified-JDK list does not cover our actual upstream JDK.** Registry inspection of `geoservercloud/geoserver-cloud-wps:3.0.0` and `geoservercloud/geoserver-acl:3.0.0` (via the Docker Registry HTTP API, no daemon needed) confirms both run a full **Eclipse Temurin JDK 25** (`JAVA_HOME=/opt/java/openjdk`, `JAVA_VERSION=jdk-25.0.3+9`) on Ubuntu 26.04 — so the earlier "JRE-only/jlink" risk is resolved (it is a full JDK). But `jaz`'s own install docs certify tuning only for **Eclipse Temurin at JDK 8** and **Microsoft Build of OpenJDK at 11/17/21/25** — Temurin 25 is on neither list. `jaz` will still start the app ("best effort" mode: prints `jaz: WARNING: Detected version of Java that has not been certified by jaz.` to stderr) but may skip its full tuning adjustments. This is more serious than the original risk because there is no config fix — only switching the JDK distribution itself (e.g., to `mcr.microsoft.com/openjdk/jdk:25-ubuntu`) would reach certified status, which is a materially bigger change than "layer a launcher on top of the unmodified upstream image." → **Mitigation:** treat this as exactly what the pilot (task group 4) is for — measure whether best-effort mode still yields a real startup/tuning improvement before deciding whether a JDK-distribution swap is worth its added risk. The sign-off gate (task group 5) is the checkpoint to stop here if not.
- [Risk] `jaz` is public preview — behavior, packaging, or defaults can change without GA stability guarantees. → **Mitigation:** pin the exact `jaz` package version per install channel; upgrade it deliberately, like any other pinned dependency.
- [Risk] `jaz` sends telemetry to Microsoft by default with no confirmed opt-out (`JAZ_EXIT_WITHOUT_FLUSH` only skips the flush delay and "might still send telemetry" per Microsoft's own docs). This is a BC Gov ALZ data-egress question, not only a technical one. → **Mitigation:** explicit sign-off gate before expanding past the pilot into test/prod (see tasks.md); if disallowed, the change stops at "evaluated, not adopted" for the pilot service only.
- [Risk] Moving 9 images from `importImage` (near-instant) to `az acr build` (a real server-side Docker build) adds wall-clock time to `terraform apply` and couples image build success into the apply's critical path. → **Mitigation:** trigger hashes cover {Dockerfile contents, `jaz_version`, upstream tag} exactly like `build_proxy_image` already does, so unrelated applies skip unchanged builds. If apply time becomes a real problem, revisit Decision 2.
- **[Risk — CONFIRMED, more complex than assumed] The 9 services do not share one entrypoint/CMD shape.** Registry inspection found two distinct shapes: `wps` (and presumably the other geoserver-cloud monorepo services — webui/wms/wfs/wcs/rest/gwc/gateway not yet individually confirmed) carries the `java` invocation in **CMD**, behind an unrelated `ENTRYPOINT ["/__cacert_entrypoint.sh"]` (a Paketo buildpacks CA-certificate bootstrap step that must be preserved, not discarded); `acl` carries the `java` invocation inside **ENTRYPOINT** itself, with `CMD` only supplying `${APP_ARGS}`. `jaz`'s own docs confirm there is no java-binary shim/replace mechanism (no env var to point `jaz` at a separate real `java`) — every literal `java` call site must become `jaz`. → **Mitigation:** the shared Dockerfile takes the exact original launch command as a per-service `ARG` (verbatim, captured once per upstream version bump) rather than assuming a single hardcoded override works for all 9; Terraform supplies the right one per service. Confirm each of the remaining 7 services' actual shape during task 6.1 (the expand step) rather than assuming they match `wps`.
- [Trade-off] A shared Dockerfile (Decision 1) means a bug in the shared jaz-install layer affects all 9 services on the next full rebuild, rather than being isolated to one file. Accepted: the alternative (9 near-identical files) has a worse real-world failure mode — silent drift when one file gets patched and the other 8 don't.

## Migration Plan

1. **Pilot:** build and deploy `wps` via the new Dockerfile/jaz path in `dev`; confirm `jaz`'s tuning output appears in Log Analytics and `wps` still responds correctly through the existing gateway path (`https://gateway.<domain>/geoserver/cloud/wps/...`).
2. **Sign-off checkpoint:** resolve the telemetry/data-egress question (Risks) before touching any other service, and before this runs in `test` or `prod` regardless of pilot outcome.
3. **Expand:** extend the Terraform `for_each` to the remaining OWS/webui services, then `gateway` and `acl` last, once the mechanism is validated on lower-risk services.
4. **Cut over per service:** remove a service's entry from `local.registry_images` only once its build path is live — import and build paths coexist per-service during the rollout, so there is no big-bang cutover.

**Rollback:** per-service. Pointing a service's `image` back at its imported tag and re-adding its `registry_images` entry reverts that one service; nothing else in the stack depends on the build path existing.

## Open Questions

- Does BC Gov ALZ policy permit `jaz`'s default telemetry egress to Microsoft? Blocks rollout past the pilot.
- ~~Is the upstream `geoserver-cloud` base image a full JDK or a JRE/jlink runtime?~~ **Resolved:** full Eclipse Temurin JDK 25, confirmed by direct registry inspection (see Risks). The open question now is narrower: given Temurin 25 isn't on `jaz`'s certified list, does best-effort mode still measurably help? Only the pilot can answer that.
- Once `jaz`'s effect on startup/warmup time is measured from the pilot, should any of the `min_replicas=1` services (set 2026-06-27 as a cold-start-incident stopgap) be revisited for scale-to-zero? Follow-up, not part of this change.
