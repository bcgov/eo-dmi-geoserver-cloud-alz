# modules/network
# Manages the GeoServer Cloud subnet footprint within the platform-provided spoke VNet.
#
# The private endpoints subnet is pre-existing (created by the BC Gov Public Cloud
# team) and is referenced via a data source only — never modified.
#
# The ACA subnet is created by this module via azapi_resource. Using the azapi
# subnet resource (rather than azurerm_subnet) avoids needing write access at the
# networking RG level: the SP only needs Network Contributor on the VNet or subnet
# scope, which the BC Gov ALZ workload-team permission set grants.
#
# Subnet layout in 10.46.10.0/24 (b9cee3-tools-vwan-spoke):
#   10.46.10.0/27   privateendpoints-subnet   EXISTING — data source only
#   10.46.10.64/26  AzureBastionSubnet        EXISTING — not touched
#   10.46.10.128/28 jumpbox-subnet            EXISTING — not touched
#   var.aca_subnet_cidr                       CREATED HERE (e.g. 10.46.10.32/27)

# ---------------------------------------------------------------------------
# VNet — data source only (locked networking RG, never modified)
# ---------------------------------------------------------------------------
data "azurerm_virtual_network" "this" {
  name                = var.vnet_name
  resource_group_name = var.vnet_resource_group_name
}

# ---------------------------------------------------------------------------
# Private endpoints subnet — pre-existing, reuse via data source
# ---------------------------------------------------------------------------
data "azurerm_subnet" "private_endpoints" {
  name                 = var.private_endpoints_subnet_name
  virtual_network_name = data.azurerm_virtual_network.this.name
  resource_group_name  = var.vnet_resource_group_name
}

# ---------------------------------------------------------------------------
# ACA subnet NSG
# Rules follow the minimal-permit pattern used by the reference (ai-hub-tracking):
#   Outbound — ACA control plane + pull path service tags
#   Inbound  — VNet east-west (ACA internal LB + service-to-service)
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "aca" {
  name                = "${var.name_prefix}-aca-nsg"
  location            = var.location
  resource_group_name = var.vnet_resource_group_name

  # ACA → ACR (image pulls; also covers the ACR private endpoint in the VNet)
  security_rule {
    name                       = "AllowAcrOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureContainerRegistry"
  }

  # ACA → Log Analytics / Azure Monitor (container logs + metrics)
  security_rule {
    name                       = "AllowMonitorOutbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureMonitor"
  }

  # ACA → Azure AD (managed identity token endpoint, OIDC)
  security_rule {
    name                       = "AllowAadOutbound"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureActiveDirectory"
  }

  # ACA → Azure Storage (ACA control plane; also covers FTPS for Dapr state)
  security_rule {
    name                       = "AllowStorageOutbound"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Storage"
  }

  # ACA east-west — service-to-service within the VNet (Key Vault PE, Postgres PE,
  # RabbitMQ on ACA, and the internal load balancer gateway → OWS services)
  security_rule {
    name                       = "AllowVnetOutbound"
    priority                   = 140
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  # Inbound from VNet — internal ACA load balancer health probes and
  # gateway → downstream OWS service routing
  security_rule {
    name                       = "AllowVnetInbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  # AzureLoadBalancer health probes (required for ACA internal LB)
  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    priority                   = 210
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  tags = var.common_tags

  lifecycle {
    ignore_changes = [tags]
  }
}

# ---------------------------------------------------------------------------
# ACA subnet — created via azapi so subnet-level operations in the locked
# networking RG don't require RG-level write access.
# The VNet lock serialises concurrent subnet modifications.
# ---------------------------------------------------------------------------
resource "azapi_resource" "aca_subnet" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2023-04-01"
  name      = "aca-subnet"
  parent_id = data.azurerm_virtual_network.this.id
  locks     = [data.azurerm_virtual_network.this.id]

  body = {
    properties = {
      addressPrefix = var.aca_subnet_cidr

      networkSecurityGroup = {
        id = azurerm_network_security_group.aca.id
      }

      # Delegation to ACA workload profiles mode
      delegations = [
        {
          name = "Microsoft.App.environments"
          properties = {
            serviceName = "Microsoft.App/environments"
          }
        }
      ]
    }
  }

  response_export_values = ["*"]
}

# ---------------------------------------------------------------------------
# App Service VNet-integration subnet NSG
# Allows outbound to VNet (KV PE, ACA gateway) and internet 443 (Keycloak).
# Deny-all implicit default prevents other traffic.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "appservice" {
  name                = "${var.name_prefix}-appservice-nsg"
  location            = var.location
  resource_group_name = var.vnet_resource_group_name

  security_rule {
    name                       = "AllowVnetOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowInternetOutbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Internet"
  }

  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  tags = var.common_tags

  lifecycle {
    ignore_changes = [tags]
  }
}

# ---------------------------------------------------------------------------
# App Service VNet-integration subnet
# Delegated to Microsoft.Web/serverFarms (required for regional VNet integration).
# Created AFTER the ACA subnet to serialise writes against the same VNet parent.
# defaultOutboundAccess = false enforces BC Gov Zero Trust / private-subnet policy.
# ---------------------------------------------------------------------------
resource "azapi_resource" "appservice_subnet" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2023-04-01"
  name      = "appservice-subnet"
  parent_id = data.azurerm_virtual_network.this.id
  locks     = [data.azurerm_virtual_network.this.id]
  # defaultOutboundAccess is not in the azapi 2023-04-01 schema but IS accepted
  # by the ARM API; skip client-side schema validation so we can set it.
  schema_validation_enabled = false

  body = {
    properties = {
      addressPrefix         = var.app_service_subnet_cidr
      defaultOutboundAccess = false

      networkSecurityGroup = {
        id = azurerm_network_security_group.appservice.id
      }

      delegations = [
        {
          name = "Microsoft.Web.serverFarms"
          properties = {
            serviceName = "Microsoft.Web/serverFarms"
          }
        }
      ]
    }
  }

  response_export_values = ["*"]

  depends_on = [azapi_resource.aca_subnet]
}
