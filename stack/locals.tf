locals {
  # ---------------------------------------------------------------------------
  # Derived resource names — auto-computed from project+environment unless the
  # caller supplies an override via the corresponding variable.
  # ---------------------------------------------------------------------------
  log_analytics_name             = coalesce(var.log_analytics_name, "log-${var.project}-${var.environment}")
  container_app_environment_name = coalesce(var.container_app_environment_name, "cae-${var.project}-${var.environment}")
  uami_name                      = coalesce(var.uami_name, "id-${var.project}-${var.environment}")

  # Pre-computed resource ID for the Log Analytics workspace.
  # All three components (subscription, RG name, workspace name) are known at
  # plan time, so this string is fully resolved — avoiding the AVM registry
  # module's for_each failure when module.observability.id is unknown-after-apply.
  log_analytics_resource_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.OperationalInsights/workspaces/${local.log_analytics_name}"

  # ---------------------------------------------------------------------------
  # GeoServer Cloud 3.0 "full OWS set" in STANDALONE mode.
  # Keys are Container App names and internal ACA hostnames the gateway routes to.
  # Only the gateway has external ingress; all others are service-to-service.
  # ---------------------------------------------------------------------------
  services = {
    gateway = { repo = "geoserver-cloud-gateway", port = 8080, external = true, extra_env = {
      GEOSERVER_BASE_PATH = "/geoserver/cloud"
      # ACA serves a valid Microsoft-managed TLS cert on the default domain, but keep the
      # insecure trust manager as belt-and-suspenders for internal service-to-service TLS
      # (SAN/hostname edge cases when traffic transits the internal LB / private endpoint).
      SPRING_CLOUD_GATEWAY_HTTPCLIENT_SSL_USEINSECURETRUSTMANAGER = "true"
      # ---------------------------------------------------------------------------
      # Backend service targets.
      #
      # The gateway routes (config/gateway-service.yml in geoserver-cloud-config) do NOT
      # use service discovery — each route is "uri: ${targets.<svc>}". In the 'standalone'
      # Spring profile those placeholders default to plain http://<svc>:8080, i.e. the
      # docker-compose service host on the container port. On ACA that name resolves to the
      # Kubernetes ClusterIP on the pod's target port (8080), which the platform
      # NetworkPolicy blocks (direct pod-to-pod) — every route then times out (HTTP 500).
      #
      # Override the targets to each service's ACA ingress FQDN over HTTPS (443) so traffic
      # flows through Envoy instead. SPRING_APPLICATION_JSON is the highest-precedence
      # property source and expresses the exact property names (including the literal hyphen
      # in 'webui-demo', which env-var relaxed binding cannot represent unambiguously).
      SPRING_APPLICATION_JSON = jsonencode({
        targets = {
          wms          = "https://wms.${module.container_app_environment.default_domain}"
          wfs          = "https://wfs.${module.container_app_environment.default_domain}"
          wcs          = "https://wcs.${module.container_app_environment.default_domain}"
          wps          = "https://wps.${module.container_app_environment.default_domain}"
          rest         = "https://rest.${module.container_app_environment.default_domain}"
          gwc          = "https://gwc.${module.container_app_environment.default_domain}"
          webui        = "https://webui.${module.container_app_environment.default_domain}"
          "webui-demo" = "https://webui.${module.container_app_environment.default_domain}"
          acl          = "https://acl.${module.container_app_environment.default_domain}"
        }
      })
    } }
    webui = { repo = "geoserver-cloud-webui", port = 8080, external = true, extra_env = {} }
    wms   = { repo = "geoserver-cloud-wms", port = 8080, external = true, extra_env = {} }
    wfs   = { repo = "geoserver-cloud-wfs", port = 8080, external = true, extra_env = {} }
    wcs   = { repo = "geoserver-cloud-wcs", port = 8080, external = true, extra_env = {} }
    wps   = { repo = "geoserver-cloud-wps", port = 8080, external = true, extra_env = { SPRING_PROFILES_ACTIVE = "standalone,pgconfig" } }
    rest  = { repo = "geoserver-cloud-rest", port = 8080, external = true, extra_env = {} }
    gwc   = { repo = "geoserver-cloud-gwc", port = 8080, external = true, extra_env = {} }
  }

  # Images imported into ACR via the server-side importImage API (no Docker daemon).
  # Sources are Docker Hub; targets match the login_server/<repo>:<tag> references
  # used by the service/acl/rabbitmq modules. Keep in sync with services map above.
  registry_images = concat(
    [for k, v in local.services : {
      source_registry = "docker.io"
      source_image    = "geoservercloud/${v.repo}:${var.gs_cloud_version}"
      target          = "${v.repo}:${var.gs_cloud_version}"
    }],
    [
      {
        source_registry = "docker.io"
        source_image    = "geoservercloud/geoserver-acl:${var.acl_version}"
        target          = "geoserver-acl:${var.acl_version}"
      },
      {
        source_registry = "docker.io"
        source_image    = "library/rabbitmq:${var.rabbitmq_image_tag}"
        target          = "rabbitmq:${var.rabbitmq_image_tag}"
      },
      {
        source_registry = "docker.io"
        source_image    = "library/postgres:18-alpine"
        target          = "postgres:18-alpine"
      },
    ]
  )

  # Plain env shared by every OWS service.
  # GeoServer Cloud (standalone + pgconfig profile) reads the database connection
  # from the JNDI datasource configured in /etc/gscloud/jndi.yml inside the image.
  # That file has a static default URL (jdbc:postgresql://pgconfigdb:5432/pgconfig),
  # so we must override the JNDI datasource properties directly — not the higher-level
  # pgconfig.host/pgconfig.database properties which only affect the backend metadata.
  common_env = merge({
    SPRING_PROFILES_ACTIVE = var.spring_profiles_active

    # JNDI datasource for pgconfig catalog backend (maps to jndi.datasources.pgconfig.*)
    JNDI_DATASOURCES_PGCONFIG_URL      = "jdbc:postgresql://${module.postgres.fqdn}:5432/${module.postgres.config_database_name}"
    JNDI_DATASOURCES_PGCONFIG_USERNAME = module.postgres.administrator_login
    JNDI_DATASOURCES_PGCONFIG_SCHEMA   = "pgconfig"

    # pgconfig backend metadata (schema, init flag — maps to pgconfig.schema / pgconfig.initialize)
    PGCONFIG_SCHEMA     = "pgconfig"
    PGCONFIG_INITIALIZE = "true"

    GEOSERVER_BUS_ENABLED = "true"
    RABBITMQ_HOST         = module.container_app_environment.static_ip_address
    RABBITMQ_PORT         = "5672"
    RABBITMQ_USER         = var.rabbitmq_user

    ACL_URL      = "https://acl.internal.${module.container_app_environment.default_domain}/acl/api"
    ACL_USERNAME = "geoserver"

    GEOWEBCACHE_CACHE_DIR = "/tmp/geowebcache"
  }, var.extra_service_env)

  common_secret_env = [
    # JNDI datasource password (maps to jndi.datasources.pgconfig.password)
    { name = "JNDI_DATASOURCES_PGCONFIG_PASSWORD", secret_name = "postgres-password" },
    { name = "RABBITMQ_PASSWORD", secret_name = "rabbitmq-password" },
    { name = "ACL_PASSWORD", secret_name = "acl-geoserver-password-plain" },
  ]

  # KV versionless secret URIs — constructed from the known vault name and secret
  # names so no azurerm_key_vault_secret data source (which puts values in state)
  # is needed. Container Apps resolve the current version at runtime via UAMI.
  _kv = "https://${var.key_vault_name}.vault.azure.net/secrets"

  service_secrets = [
    { name = "acr-password", key_vault_secret_id = "${local._kv}/acr-password" },
    { name = "postgres-password", key_vault_secret_id = "${local._kv}/postgres-password" },
    { name = "rabbitmq-password", key_vault_secret_id = "${local._kv}/rabbitmq-password" },
    { name = "acl-geoserver-password-plain", key_vault_secret_id = "${local._kv}/acl-geoserver-password-plain" },
  ]

  acl_env = {
    PG_HOST               = module.postgres.fqdn
    PG_PORT               = "5432"
    PG_DB                 = module.postgres.config_database_name
    PG_USERNAME           = module.postgres.administrator_login
    PG_SCHEMA             = "acl"
    GEOSERVER_BUS_ENABLED = "true"
    # Use the stable .internal. FQDN — always resolvable within the CAE
    # regardless of whether RabbitMQ's external_ingress is true or false.
    # module.rabbitmq.fqdn flips between *.internal.* and *.* when external
    # changes, causing a Terraform plan inconsistency on mid-apply.
    RABBITMQ_HOST = module.container_app_environment.static_ip_address
    RABBITMQ_PORT = "5672"
    RABBITMQ_USER = var.rabbitmq_user
  }

  acl_secret_env = [
    { name = "PG_PASSWORD", secret_name = "postgres-password" },
    { name = "RABBITMQ_PASSWORD", secret_name = "rabbitmq-password" },
    { name = "ACL_USERS_ADMIN_PASSWORD", secret_name = "acl-admin-password" },
    { name = "ACL_USERS_GEOSERVER_PASSWORD", secret_name = "acl-geoserver-password" },
  ]

  acl_secrets = [
    { name = "acr-password", key_vault_secret_id = "${local._kv}/acr-password" },
    { name = "postgres-password", key_vault_secret_id = "${local._kv}/postgres-password" },
    { name = "rabbitmq-password", key_vault_secret_id = "${local._kv}/rabbitmq-password" },
    { name = "acl-admin-password", key_vault_secret_id = "${local._kv}/acl-admin-password" },
    { name = "acl-geoserver-password", key_vault_secret_id = "${local._kv}/acl-geoserver-password" },
  ]
}
