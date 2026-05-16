# =============================================================================
# Root Level Outputs - Re-export module outputs
# =============================================================================

# Jumpbox Outputs
output "jumpbox_vm_id" {
  description = "ID of the jumpbox virtual machine"
  value       = var.enable_jumpbox ? module.jumpbox[0].vm_id : null
}



output "jumpbox_auto_shutdown_time" {
  description = "Auto-shutdown time (PST)"
  value       = var.enable_jumpbox ? module.jumpbox[0].auto_shutdown_time : null
}

output "jumpbox_auto_start_schedule" {
  description = "Auto-start schedule"
  value       = var.enable_jumpbox ? module.jumpbox[0].auto_start_schedule : null
}

output "jumpbox_automation_account_id" {
  description = "ID of the Azure Automation Account for jumpbox auto-start"
  value       = var.enable_jumpbox ? module.jumpbox[0].automation_account_id : null
}

output "jumpbox_entra_login_enabled" {
  description = "Whether Entra ID SSH login is enabled on the jumpbox"
  value       = var.enable_jumpbox ? module.jumpbox[0].entra_login_enabled : null
}

# Bastion Outputs
output "bastion_resource_id" {
  description = "Resource ID of Azure Bastion"
  value       = var.enable_bastion ? module.bastion[0].bastion_resource_id : null
}

output "bastion_fqdn" {
  description = "FQDN of the Bastion service"
  value       = var.enable_bastion ? module.bastion[0].bastion_fqdn : null
}


