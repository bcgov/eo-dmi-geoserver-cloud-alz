# Network Module

This module manages the application subnet footprint inside the BC Gov
platform-provided spoke VNet. It does not own the VNet or the existing private
endpoint subnet.

## Ownership

| Resource | Ownership |
| --- | --- |
| Spoke VNet | Platform-provided and read through a data source. |
| Private-endpoint subnet | Platform-provided and read through a data source. |
| ACA subnet | Created by this module and delegated to `Microsoft.App/environments`. |
| App Service subnet | Created by this module and delegated to `Microsoft.Web/serverFarms`. |
| ACA NSG | Created by this module for required Azure service tags and VNet east-west traffic. |

Do not modify the platform `*-networking` resource group outside the approved
subnet and NSG operations represented here.

## Inputs

| Input | Required | Notes |
| --- | --- | --- |
| `vnet_name` | Yes | Existing spoke VNet name. |
| `vnet_resource_group_name` | Yes | Locked networking resource group. |
| `private_endpoints_subnet_name` | Yes | Existing private endpoint subnet. |
| `aca_subnet_cidr` | Yes | Valid, non-overlapping CIDR; minimum `/27`. |
| `app_service_subnet_cidr` | No | Defaults to `10.46.10.144/28`; minimum `/28`. |
| `location` | Yes | Region used for the NSG. |
| `name_prefix` | Yes | Resource name prefix. |
| `common_tags` | No | Mandatory ALZ tags from the naming module. |

## NSG Rules

The ACA NSG allows:

- Outbound HTTPS to Azure Container Registry.
- Outbound HTTPS to Azure Monitor and Azure Active Directory.
- Outbound HTTPS to Azure Storage.
- VNet east-west traffic for ACA service routing and private endpoints.
- Inbound VNet traffic for internal load-balancer probes and gateway routing.
- Azure Load Balancer health probes.

Review platform networking policy before changing these rules. The broad VNet
rules are part of the internal ACA service-to-service design.

## Outputs

- `vnet_id`
- `aca_subnet_id`
- `private_endpoints_subnet_id`
- `app_service_subnet_id`

## Preflight

Before apply, confirm that both new CIDRs are free in the VNet and that the
private endpoint subnet exists. A DNS zone group may be attached asynchronously
by platform policy. The stack can wait for that attachment through
`private_endpoint_dns_wait` and `scripts_dir`.
