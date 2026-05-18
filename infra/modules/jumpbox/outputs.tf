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

output "automation_account_name" {
  description = "Name of the Azure Automation Account used for jumpbox and optional Bastion automation"
  value       = azurerm_automation_account.jumpbox.name
}

output "bastion_automation_enabled" {
  description = "Whether Bastion delete/recreate automation runbooks are enabled"
  value       = var.enable_bastion && var.enable_bastion_automation
}

output "bastion_create_runbook_name" {
  description = "Runbook name that recreates Bastion on demand"
  value       = var.enable_bastion && var.enable_bastion_automation ? azurerm_automation_runbook.create_bastion[0].name : null
}

output "bastion_delete_runbook_name" {
  description = "Runbook name that deletes Bastion after hours"
  value       = var.enable_bastion && var.enable_bastion_automation ? azurerm_automation_runbook.delete_bastion[0].name : null
}

output "entra_login_enabled" {
  description = "Whether Microsoft Entra ID SSH login is enabled on the jumpbox"
  value       = var.enable_entra_login
}
