# module: geoserver-service

Generic, reusable module that deploys **one** GeoServer Cloud microservice as an
Azure Container App. Instantiate it once per service via `for_each`.

- `external_ingress = true` only for the **gateway** (exposed on the environment's
  internal LB; everything else is internal-only service-to-service).
- ACR pull uses `registry_username` + a Key Vault-backed `acr-password` secret.
- App secrets (DB/RabbitMQ passwords) are Key Vault references resolved by the
  shared user-assigned identity (`uami_id`).
- `env` carries plain config; `secret_env` maps env vars to named secrets.

CPU/memory must follow ACA Consumption pairing (~1:2), e.g. `cpu=1.0`,
`memory="2Gi"`.
