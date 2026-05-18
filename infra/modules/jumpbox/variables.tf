# -----------------------------------------------------------------------------
# Jumpbox Module Variables
# -----------------------------------------------------------------------------

variable "app_name" {
  description = "Name of the application, used for resource naming"
  type        = string
  nullable    = false
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  nullable    = false
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  nullable    = false
}

variable "subnet_id" {
  description = "Subnet ID for the jumpbox VM"
  type        = string
  nullable    = false
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  nullable    = false
}

variable "vm_size" {
  description = "Size of the virtual machine (B2als_v2: 2 vCPU, 4 GB RAM - cost-effective for jumpbox)"
  type        = string
  default     = "Standard_B2als_v2"
}


variable "os_disk_type" {
  description = "Storage account type for the OS disk"
  type        = string
  default     = "StandardSSD_LRS" # Standard SSD avoids the retired Standard HDD OS disk path
}

variable "os_disk_size_gb" {
  description = "Size of the OS disk in GB"
  type        = number
  default     = 64
  nullable    = false
}

variable "enable_entra_login" {
  description = "Enable Microsoft Entra ID (AAD) SSH login on the Linux jumpbox VM via the AADSSHLoginForLinux VM extension"
  type        = bool
  default     = true
}

variable "enable_bastion" {
  description = "Whether the Bastion host is deployed for this environment"
  type        = bool
  default     = true
}

variable "enable_bastion_automation" {
  description = "Enable Azure Automation runbooks that delete and recreate Bastion on a schedule and on demand"
  type        = bool
  default     = false
}

variable "bastion_subnet_id" {
  description = "Subnet ID for Azure Bastion"
  type        = string
  default     = null
}

variable "bastion_sku" {
  description = "Bastion SKU used when the automation runbook recreates Bastion"
  type        = string
  default     = "Standard"
}

variable "bastion_tunneling_enabled" {
  description = "Enable native client tunneling when the automation runbook recreates Bastion"
  type        = bool
  default     = true
}

variable "bastion_copy_paste_enabled" {
  description = "Enable copy and paste when the automation runbook recreates Bastion"
  type        = bool
  default     = true
}

variable "bastion_file_copy_enabled" {
  description = "Enable file copy when the automation runbook recreates Bastion"
  type        = bool
  default     = false
}

variable "bastion_ip_connect_enabled" {
  description = "Enable IP Connect when the automation runbook recreates Bastion"
  type        = bool
  default     = false
}

variable "bastion_shareable_link_enabled" {
  description = "Enable shareable links when the automation runbook recreates Bastion"
  type        = bool
  default     = false
}

variable "bastion_scale_units" {
  description = "Scale units to configure when the automation runbook recreates Bastion"
  type        = number
  default     = 2
}

variable "bastion_public_ip_sku" {
  description = "SKU for the Azure Bastion public IP created by the automation runbook"
  type        = string
  default     = "Standard"
}

variable "bastion_public_ip_sku_tier" {
  description = "SKU tier for the Azure Bastion public IP created by the automation runbook"
  type        = string
  default     = "Regional"
}

variable "bastion_public_ip_allocation_method" {
  description = "Allocation method for the Azure Bastion public IP created by the automation runbook"
  type        = string
  default     = "Static"
}

variable "bastion_public_ip_version" {
  description = "IP version for the Azure Bastion public IP created by the automation runbook"
  type        = string
  default     = "IPv4"
}

variable "bastion_public_ip_idle_timeout_in_minutes" {
  description = "Idle timeout for the Azure Bastion public IP created by the automation runbook"
  type        = number
  default     = 4
}

variable "bastion_public_ip_ddos_protection_mode" {
  description = "DDoS protection mode for the Azure Bastion public IP created by the automation runbook"
  type        = string
  default     = "VirtualNetworkInherited"
}
