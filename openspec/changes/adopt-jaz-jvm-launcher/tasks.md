## Status: Abandoned (2026-07-05)

Stopped after task group 1, before any Dockerfile or Terraform code was written. Task 1.1 confirmed the upstream GeoServer Cloud images run Eclipse Temurin JDK 25, which is not on `jaz`'s certified-tuning list (certified: Temurin at JDK 8 only; Microsoft Build of OpenJDK at 11/17/21/25) — `jaz` would run in uncertified "best effort" mode with reduced or no tuning benefit, and reaching certified status would require also swapping the JDK vendor, a materially bigger change than originally scoped. Decision: not enough expected value to justify building and rolling out the Dockerfile/Terraform/build-pipeline changes at this time. Revisit if `jaz` broadens its certified JDK list, or if the project changes JDK vendor for unrelated reasons. See design.md's Risks section for the full finding.

## 1. Verify assumptions (pilot pre-work)

- [x] 1.1 Inspect the upstream `geoservercloud/geoserver-cloud-wps` image's actual Java installation to confirm it is a full JDK, not JRE-only or a custom jlink runtime; record the finding.
      **Finding (via Docker Registry HTTP API against `geoservercloud/geoserver-cloud-wps:3.0.0` and `geoservercloud/geoserver-acl:3.0.0`, no Docker daemon needed):** both are Ubuntu 26.04 base with a full **Eclipse Temurin JDK 25** (`JAVA_HOME=/opt/java/openjdk`, `JAVA_VERSION=jdk-25.0.3+9`) — confirmed full JDK, not JRE-only/jlink. However, per `jaz`'s install docs, its certified-JDK list is **Eclipse Temurin at JDK 8 only**, and **Microsoft Build of OpenJDK at 11/17/21/25** — Temurin 25 is not on that list. `jaz` will still launch the app in this "best effort" mode (prints `jaz: WARNING: Detected version of Java that has not been certified by jaz.` to stderr) but may not apply its full tuning. This materially raises the chance the pilot shows reduced or no measurable benefit unless the JDK distribution is also changed (see design.md).
- [x] 1.2 Inspect the upstream image's actual entrypoint/cmd/working directory so the new Dockerfile can reproduce it verbatim except for the `java` → `jaz` swap.
      **Finding:** two distinct shapes exist, not one uniform pattern —
      - `wps` (geoserver-cloud monorepo services): `ENTRYPOINT ["/__cacert_entrypoint.sh"]`, `CMD ["/bin/sh","-c","exec java $JAVA_OPTS -XX:AOTMode=$AOT_MODE -XX:AOTCache=app.aot org.springframework.boot.loader.launch.JarLauncher"]` — the `java` invocation lives in **CMD**; `ENTRYPOINT` is a Paketo buildpacks CA-certificate bootstrap script that must not be discarded.
      - `acl`: `ENTRYPOINT ["/bin/bash","-c","exec java -XX:AOTMode=$AOT_MODE -XX:AOTCache=app.aot $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher \"${@}\"","--"]`, `CMD ["${APP_ARGS}"]` — the `java` invocation lives in **ENTRYPOINT** instead.
      - Both already `exec java ...` (correct signal propagation preserved today) and both already carry substantial container-aware tuning via the image's own `JAVA_TOOL_OPTIONS` env var (`-XX:MaxRAMPercentage=80`, GC/heap flags) — this is picked up by the JVM automatically regardless of launcher and predates this change.
      - Confirmed via `jaz` install docs: there is no java-binary shim/replace mechanism and no env var pointing `jaz` at a separate real `java` — each call site's literal `java` token must be swapped for `jaz`, so the shared Dockerfile must accept the exact original launch command as a per-service build arg rather than assuming one fixed CMD/ENTRYPOINT shape for all 9 services.
- [ ] 1.3 Confirm with the BC Gov ALZ / data-governance owner whether `jaz`'s default telemetry egress to Microsoft is acceptable; record the decision before starting task group 5.

## 2. Dockerfile

- [ ] 2.1 Create `infra/docker/geoserver-cloud-jaz/Dockerfile` with `ARG BASE_IMAGE`, installing the pinned `jaz` version via the Microsoft package repository (matching the base OS confirmed in 1.1/1.2), with an entrypoint/cmd that reproduces the upstream image's original launch command with `java` replaced by `jaz`.
- [ ] 2.2 Keep the build context minimal (no application source to copy — only the Dockerfile is needed).
- [ ] 2.3 Build the pilot image via `az acr build` with `BASE_IMAGE=geoservercloud/geoserver-cloud-wps:<tag>` and confirm the container starts and `jaz`'s tuning output appears in the logs.

## 3. Terraform — pilot wiring

- [ ] 3.1 Add a `jaz_version` variable to `infra/stack/variables.tf` (mirrors `gs_cloud_version` / `acl_version`).
- [ ] 3.2 Add a local in `infra/stack/locals.tf` identifying which of the 9 services build via jaz vs. still import (starts with only `wps` on the build path).
- [ ] 3.3 Remove `wps`'s entry from `local.registry_images` (it will no longer be imported).
- [ ] 3.4 Add a `null_resource` build resource in `infra/stack/main.tf` for the pilot service, following `null_resource.build_proxy_image`'s pattern: trigger hash over {Dockerfile contents, `jaz_version`, upstream tag}, `az acr build` inside the `local-exec` provisioner.
- [ ] 3.5 Confirm `module.service["wps"]`'s `image` argument still resolves to `${module.registry.login_server}/${repo}:${tag}` — same shape as today, now populated by build instead of import.
- [ ] 3.6 `terraform fmt`, `terraform validate`, `tflint`, and `checkov` pass locally for the changed files.

## 4. Pilot verification (dev)

- [ ] 4.1 Apply to `dev` via the existing `local-run.sh apply` workflow; confirm the `wps` image build runs and the Container App comes up healthy.
- [ ] 4.2 Check Log Analytics for the `wps` Container App's startup logs; confirm `jaz`'s tuning output is present rather than an uncertified-JDK warning (unless 1.1 already found that to be expected).
- [ ] 4.3 Exercise `wps` through the existing gateway test path (`https://gateway.<domain>/geoserver/cloud/wps/...` over the SOCKS5 bastion tunnel) and confirm it still responds correctly.
- [ ] 4.4 Restart the `wps` replica and confirm graceful shutdown/restart behavior is unchanged (clean exit code in logs, no orphaned process).

## 5. Sign-off gate

- [ ] 5.1 Review the pilot results (task groups 2-4) together with the telemetry/data-egress decision (1.3); decide go/no-go for expanding beyond the pilot.
- [ ] 5.2 If no-go, document the decision and stop here (the pilot service can stay on jaz or be reverted per the finding).

## 6. Expand to remaining services

- [ ] 6.1 Add the remaining OWS/webui services (webui, wms, wfs, wcs, rest, gwc) to the build local and the `for_each` build matrix; remove their entries from `registry_images`.
- [ ] 6.2 Add `gateway` and `acl` last, once the OWS/webui rollout is verified stable.
- [ ] 6.3 Repeat the task-group-4 verification (startup logs, functional check through the gateway, restart behavior) for each newly added service — `gateway` and `acl` need their own check since they sit on the routing/authorization path.
- [ ] 6.4 Confirm `local.registry_images` now contains only `rabbitmq` and `postgres`.

## 7. Rollout to test/prod

- [ ] 7.1 Add `TF_VAR_jaz_version` (or the variable name chosen in 3.1) to the `test` and `prod` GitHub Environments, per the convention documented in `terraform-deploy.yml`.
- [ ] 7.2 Run the gated `test` deploy (`cd-test.yml`) and repeat task-group-4-style verification.
- [ ] 7.3 Run the gated `prod` deploy (`cd-prod.yml`) and repeat verification.

## 8. Documentation

- [ ] 8.1 Document the new Dockerfile/build mechanism and the jaz adoption decision in the project's existing docs/runbook.
- [ ] 8.2 Record the telemetry/data-egress decision (5.1) in the same documentation for future reference.
