# =============================================================================
# Root Level Outputs - Re-export module outputs
# =============================================================================

# Jumpbox Outputs
output "jumpbox_vm_id" {
  description = "ID of the jumpbox virtual machine"
  value       = var.enable_jumpbox ? module.jumpbox[0].vm_id : null
}

output "jumpbox_admin_username" {
  description = "Admin username for the jumpbox VM"
  value       = var.enable_jumpbox ? module.jumpbox[0].admin_username : null
}

output "jumpbox_bootstrap_ssh_private_key" {
  description = "Bootstrap SSH private key retained in Terraform state for break-glass access"
  value       = var.enable_jumpbox ? module.jumpbox[0].bootstrap_ssh_private_key : null
  sensitive   = true
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

output "jumpbox_automation_account_name" {
  description = "Name of the Azure Automation Account used for jumpbox and optional Bastion automation"
  value       = var.enable_jumpbox ? module.jumpbox[0].automation_account_name : null
}

output "bastion_automation_enabled" {
  description = "Whether Bastion delete/recreate automation runbooks are enabled"
  value       = var.enable_jumpbox ? module.jumpbox[0].bastion_automation_enabled : null
}

output "bastion_create_runbook_name" {
  description = "Runbook name that recreates Bastion on demand"
  value       = var.enable_jumpbox ? module.jumpbox[0].bastion_create_runbook_name : null
}

output "bastion_delete_runbook_name" {
  description = "Runbook name that deletes Bastion after hours"
  value       = var.enable_jumpbox ? module.jumpbox[0].bastion_delete_runbook_name : null
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


