output "common_tags" {
  description = "Mandatory ALZ tags merged with any extra tags; spread onto every resource."
  value       = local.common_tags
}

output "name_prefix" {
  description = "Resource name prefix, e.g. geoserver-dev."
  value       = local.name_prefix
}
