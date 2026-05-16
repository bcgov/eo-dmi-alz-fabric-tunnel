output "jumpbox_subnet_id" {
  description = "The subnet ID for the Jumpbox VM."
  value       = azapi_resource.jumpbox_subnet.id
}

output "bastion_subnet_id" {
  description = "The subnet ID for Azure Bastion."
  value       = azapi_resource.bastion_subnet.id
}

output "dns_servers" {
  description = "The DNS servers for the virtual network."
  value       = data.azurerm_virtual_network.main.dns_servers
}

output "vnet_id" {
  description = "ID of the virtual network"
  value       = data.azurerm_virtual_network.main.id
}

output "vnet_name" {
  description = "Name of the virtual network"
  value       = data.azurerm_virtual_network.main.name
}

