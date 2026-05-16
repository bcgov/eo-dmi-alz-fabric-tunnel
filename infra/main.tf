# -------------
# Root Level Terraform Configuration
# -------------
# Create the main resource group for all application resources
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.common_tags
  lifecycle {
    ignore_changes = [
      tags
    ]
  }
}

# -------------
# Modules based on Dependency
# -------------
module "network" {
  source = "./modules/network"

  common_tags              = var.common_tags
  resource_group_name      = azurerm_resource_group.main.name
  vnet_address_space       = var.vnet_address_space
  vnet_name                = var.vnet_name
  vnet_resource_group_name = var.vnet_resource_group_name
  depends_on               = [azurerm_resource_group.main]
}
module "monitoring" {
  source = "./modules/monitoring"

  app_name                     = var.app_name
  common_tags                  = var.common_tags
  location                     = var.location
  log_analytics_retention_days = var.log_analytics_retention_days
  log_analytics_sku            = var.log_analytics_sku
  resource_group_name          = azurerm_resource_group.main.name

  depends_on = [azurerm_resource_group.main, module.network]
}
module "bastion" {
  source = "./modules/bastion"
  count  = var.enable_bastion ? 1 : 0

  app_name            = var.app_name
  common_tags         = var.common_tags
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  bastion_subnet_id   = module.network.bastion_subnet_id
  bastion_sku         = "Standard"

}
module "jumpbox" {
  source = "./modules/jumpbox"
  count  = var.enable_jumpbox ? 1 : 0

  app_name                     = var.app_name
  common_tags                  = var.common_tags
  location                     = var.location
  resource_group_name          = azurerm_resource_group.main.name
  subnet_id                    = module.network.jumpbox_subnet_id
  enable_entra_login           = var.enable_entra_login
  vm_admin_login_principal_ids = var.vm_admin_login_principal_ids
  depends_on                   = [module.network]
}

