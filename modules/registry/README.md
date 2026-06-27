# module: registry

Standard Azure Container Registry with the admin user enabled and **no** private
endpoint (an ALZ-accepted configuration). Exports `login_server`,
`admin_username`, and `admin_password` (sensitive). The stack stores the
credentials in Key Vault; Container Apps reference them as registry secrets.

## Image sourcing (Terraform-native)

Pass the images to load via the `images` variable. The module imports each one
into the registry using the server-side ACR `importImage` action (the `azapi`
provider) — no Docker daemon and no `az acr import` shell-out. The import runs
during `terraform apply`, and the consuming stack `depends_on` this module, so
the Container Apps never start before their images exist.

```hcl
images = [
  { source_registry = "docker.io", source_image = "geoservercloud/geoserver-cloud-wms:3.0.0", target = "geoserver-cloud-wms:3.0.0" },
  # ...
]
```

Each entry is re-imported with `mode = "Force"` on every apply, keeping the tag
in sync with the pinned version. Leave `images = []` to skip import (e.g. when a
separate pipeline pushes the images).
