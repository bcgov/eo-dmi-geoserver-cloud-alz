# module: container-app-environment

Workload-profiles Azure Container Apps environment, VNet-integrated into the
platform's delegated subnet with `internal_load_balancer_enabled = true` (no
public ingress — ALZ requirement). Also creates the **user-assigned managed
identity** shared by every GeoServer Cloud app for Key Vault reads and ACR pulls.

Outputs the environment `id`/`default_domain`/`static_ip_address` and the
identity's `uami_id`/`uami_principal_id`/`uami_client_id`.
