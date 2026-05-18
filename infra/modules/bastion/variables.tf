# -----------------------------------------------------------------------------
# Bastion Module Variables
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

variable "bastion_subnet_id" {
  description = "Subnet ID for Azure Bastion (must be named AzureBastionSubnet)"
  type        = string
  nullable    = false
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  nullable    = false
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace that receives Bastion audit logs."
  type        = string
  nullable    = false
}

variable "bastion_sku" {
  description = "SKU for Azure Bastion (Basic or Standard)"
  type        = string
  default     = "Standard"
  nullable    = false

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.bastion_sku)
    error_message = "Bastion SKU must be Basic, Standard, or Premium."
  }
}

variable "tunneling_enabled" {
  description = "Enable native client tunneling (az network bastion ssh/tunnel). Requires Standard or Premium SKU."
  type        = bool
  default     = true
}

variable "copy_paste_enabled" {
  description = "Enable copy and paste support in Azure Bastion sessions."
  type        = bool
  default     = true
}

variable "file_copy_enabled" {
  description = "Enable file copy support in Azure Bastion sessions."
  type        = bool
  default     = false
}

variable "ip_connect_enabled" {
  description = "Enable Azure Bastion IP Connect."
  type        = bool
  default     = false
}

variable "shareable_link_enabled" {
  description = "Enable Azure Bastion shareable links."
  type        = bool
  default     = false
}

variable "scale_units" {
  description = "Scale units to configure on the Azure Bastion host."
  type        = number
  default     = 2
}

variable "public_ip_sku" {
  description = "SKU for the Azure Bastion public IP."
  type        = string
  default     = "Standard"
}

variable "public_ip_sku_tier" {
  description = "SKU tier for the Azure Bastion public IP."
  type        = string
  default     = "Regional"
}

variable "public_ip_allocation_method" {
  description = "Allocation method for the Azure Bastion public IP."
  type        = string
  default     = "Static"
}

variable "public_ip_version" {
  description = "IP version for the Azure Bastion public IP."
  type        = string
  default     = "IPv4"
}

variable "public_ip_idle_timeout_in_minutes" {
  description = "Idle timeout in minutes for the Azure Bastion public IP."
  type        = number
  default     = 4
}

variable "public_ip_ddos_protection_mode" {
  description = "DDoS protection mode for the Azure Bastion public IP."
  type        = string
  default     = "VirtualNetworkInherited"
}
