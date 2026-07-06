# modules/naming
# Pure-locals module: produces the mandatory BC Gov ALZ tag set and a consistent
# resource name prefix. No Azure resources are created here.

locals {
  # Mandatory ALZ tags applied to every resource via merge(local.common_tags, ...).
  mandatory_tags = {
    ministry_name = var.ministry_name
    environment   = var.environment
  }

  common_tags = merge(local.mandatory_tags, var.extra_tags)

  # e.g. "geoserver-dev"
  name_prefix = "${var.project}-${var.environment}"
}
