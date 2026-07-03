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
    # Gateway: external = true so the App Service can reach it via VNet integration.
    # All other services are internal-only; gateway routes to them via .internal. FQDNs.
    gateway = {
      repo     = "geoserver-cloud-gateway"
      port     = 8080
      external = true
      sticky   = false
      # Per-service scaling + resources (independent per GeoServer Cloud service).
      # cpu/memory must be a valid ACA Consumption pair (0.25:0.5Gi, 0.5:1Gi,
      # 0.75:1.5Gi, 1.0:2Gi, 1.25:2.5Gi … 2.0:4Gi). Tune per load test.
      # min_replicas = 1: the gateway is the single entry point the Node proxy talks
      # to. At 0 it scales to zero and the first request after idle cold-starts —
      # which the user sees as "Bad Gateway" while the proxy waits for the cold
      # gateway. Keep it warm.
      min_replicas = 1
      max_replicas = 3
      cpu          = 2.0
      memory       = "4Gi"
      extra_env = {
        GEOSERVER_BASE_PATH                                         = "/geoserver/cloud"
        SPRING_CLOUD_GATEWAY_HTTPCLIENT_SSL_USEINSECURETRUSTMANAGER = "true"
        # Use .internal. FQDNs — backends are internal-only (external = false).
        # .internal. is resolvable within the ACA environment for all services.
        SPRING_APPLICATION_JSON = jsonencode({
          targets = {
            wms          = "https://wms.internal.${module.container_app_environment.default_domain}"
            wfs          = "https://wfs.internal.${module.container_app_environment.default_domain}"
            wcs          = "https://wcs.internal.${module.container_app_environment.default_domain}"
            wps          = "https://wps.internal.${module.container_app_environment.default_domain}"
            rest         = "https://rest.internal.${module.container_app_environment.default_domain}"
            gwc          = "https://gwc.internal.${module.container_app_environment.default_domain}"
            webui        = "https://webui.internal.${module.container_app_environment.default_domain}"
            "webui-demo" = "https://webui.internal.${module.container_app_environment.default_domain}"
            acl          = "https://acl.internal.${module.container_app_environment.default_domain}"
          }
        })
      }
    }
    # webui: sticky sessions required for Wicket page state; min 1 so the OIDC
    # proxy's sec-username header always lands on a warm replica.
    webui = { repo = "geoserver-cloud-webui", port = 8080, external = false, sticky = true, min_replicas = 1, max_replicas = 2, cpu = 2, memory = "4Gi", extra_env = {} }
    wms   = { repo = "geoserver-cloud-wms", port = 8080, external = false, sticky = false, min_replicas = 1, max_replicas = 4, cpu = 2, memory = "4Gi", extra_env = {} }
    wfs   = { repo = "geoserver-cloud-wfs", port = 8080, external = false, sticky = false, min_replicas = 1, max_replicas = 3, cpu = 2, memory = "4Gi", extra_env = {} }
    wcs   = { repo = "geoserver-cloud-wcs", port = 8080, external = false, sticky = false, min_replicas = 1, max_replicas = 2, cpu = 2, memory = "4Gi", extra_env = {} }
    # wps: ACL profile excluded (WPS service does not use data-layer ACL).
    # environment-admin-auth kept so admin credentials are consistent across services.
    wps  = { repo = "geoserver-cloud-wps", port = 8080, external = false, sticky = false, min_replicas = 1, max_replicas = 2, cpu = 2, memory = "4Gi", extra_env = { SPRING_PROFILES_ACTIVE = "standalone,pgconfig,environment-admin-auth", ACL_ENABLED = "false" } }
    rest = { repo = "geoserver-cloud-rest", port = 8080, external = false, sticky = false, min_replicas = 1, max_replicas = 2, cpu = 2, memory = "4Gi", extra_env = {} }
    gwc  = { repo = "geoserver-cloud-gwc", port = 8080, external = false, sticky = false, min_replicas = 1, max_replicas = 3, cpu = 2, memory = "4Gi", extra_env = {} }
  }

  # Derived values used by the App Service resource (stack/main.tf).
  proxy_fqdn   = "${var.proxy_app_service_name}.azurewebsites.net"
  proxy_origin = "https://${local.proxy_fqdn}"
  # Gateway ingress FQDN. The gateway is external = true, so its hostname is
  # gateway.<default_domain> WITHOUT the ".internal." segment (that segment only
  # applies to internal-ingress apps like the wms/wfs/... backends). Because the
  # whole ACA environment sits behind an internal load balancer, this hostname is
  # still only resolvable/reachable from inside the spoke VNet (App Service VNet
  # integration, or the bastion SOCKS5 tunnel) — never from the public internet.
  # Hitting the ".internal." form returns HTTP 404 from Envoy (no app matches that
  # Host), which is what broke configure_geoserver_security on the first apply.
  gateway_internal = "https://gateway.${module.container_app_environment.default_domain}"

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

    # pgconfig catalog backend datasource — GeoServer Cloud 3.x property model.
    # 3.x builds the JNDI datasource (jndi.yml) from pgconfig.host/port/database/username,
    # replacing 1.x's jndi.datasources.pgconfig.url form. Password is a KV secret below.
    PGCONFIG_HOST       = module.postgres.fqdn
    PGCONFIG_PORT       = "5432"
    PGCONFIG_DATABASE   = module.postgres.config_database_name
    PGCONFIG_USERNAME   = module.postgres.administrator_login
    PGCONFIG_SCHEMA     = "pgconfig"
    PGCONFIG_INITIALIZE = "true"

    GEOSERVER_BUS_ENABLED             = "true"
    RABBITMQ_HOST                     = module.container_app_environment.static_ip_address
    RABBITMQ_PORT                     = "5672"
    RABBITMQ_USER                     = var.rabbitmq_user
    SPRING_CONFIG_ADDITIONAL_LOCATION = "/etc/gscloud/deployment-config/"

    ACL_URL      = "https://acl.internal.${module.container_app_environment.default_domain}/acl/api"
    ACL_USERNAME = "geoserver"
    # Explicitly enable ACL so the deployment-config's ${ACL_ENABLED:false} default
    # is overridden even if Spring profile config data precedence shifts across versions.
    ACL_ENABLED  = "true"

    GEOWEBCACHE_CACHE_DIR = "/tmp/geowebcache"

    # environment-admin-auth extension: sets the GeoServer web-admin username at startup.
    # The password is a KV-backed secret in common_secret_env below.
    GEOSERVER_ADMIN_USERNAME = "admin"
  }, var.extra_service_env)

  common_secret_env = [
    { name = "PGCONFIG_PASSWORD", secret_name = "postgres-password" },
    { name = "RABBITMQ_PASSWORD", secret_name = "rabbitmq-password" },
    { name = "ACL_PASSWORD", secret_name = "acl-geoserver-password-plain" },
    # environment-admin-auth: password read at GeoServer startup from this env var.
    { name = "GEOSERVER_ADMIN_PASSWORD", secret_name = "geoserver-admin-password" },
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
    { name = "geoserver-admin-password", key_vault_secret_id = "${local._kv}/geoserver-admin-password" },
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
