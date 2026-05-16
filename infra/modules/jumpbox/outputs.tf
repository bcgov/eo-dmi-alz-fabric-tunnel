# -----------------------------------------------------------------------------
# Jumpbox Module Outputs
# -----------------------------------------------------------------------------

output "vm_id" {
  description = "ID of the jumpbox virtual machine"
  value       = azurerm_linux_virtual_machine.jumpbox.id
}

output "vm_name" {
  description = "Name of the jumpbox virtual machine"
  value       = azurerm_linux_virtual_machine.jumpbox.name
}

output "private_ip_address" {
  description = "Private IP address of the jumpbox VM"
  value       = azurerm_network_interface.jumpbox.private_ip_address
}

output "admin_username" {
  description = "Local admin username required by the VM resource. Interactive access uses Entra ID SSH login."
  value       = random_string.admin_username.result
}

output "bootstrap_ssh_private_key" {
  description = "Bootstrap SSH private key retained in Terraform state for break-glass access"
  value       = azapi_resource_action.bootstrap_ssh_keypair.output.privateKey
  sensitive   = true
}

output "principal_id" {
  description = "Principal ID of the VM's managed identity"
  value       = azurerm_linux_virtual_machine.jumpbox.identity[0].principal_id
}

output "auto_shutdown_time" {
  description = "Auto-shutdown time (PST)"
  value       = "7:00 PM PST (daily)"
}

output "auto_start_schedule" {
  description = "Auto-start schedule"
  value       = "8:00 AM PST (Monday-Friday only)"
}

output "automation_account_id" {
  description = "ID of the Azure Automation Account for VM auto-start"
  value       = azurerm_automation_account.jumpbox.id
}

output "entra_login_enabled" {
  description = "Whether Microsoft Entra ID SSH login is enabled on the jumpbox"
  value       = var.enable_entra_login
}
