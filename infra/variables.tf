
variable "app_env" {
  description = "Application environment (dev, test, prod)"
  type        = string
  nullable    = false
}

variable "app_name" {
  description = "Name of the application"
  type        = string
  nullable    = false
}
variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
}
variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "Canada Central"
}
variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  nullable    = false
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
  sensitive   = true
}

variable "tenant_id" {
  description = "Azure tenant ID"
  type        = string
  sensitive   = true
}

variable "use_oidc" {
  description = "Use OIDC for authentication"
  type        = bool
  default     = true
}

variable "vnet_address_space" {
  type        = string
  description = "Address space for the virtual network, it is created by platform team"
}

variable "vnet_name" {
  description = "Name of the existing virtual network"
  type        = string
}

variable "vnet_resource_group_name" {
  description = "Resource group name where the virtual network exists"
  type        = string
}
variable "client_id" {
  description = "Azure client ID for the service principal"
  type        = string
  sensitive   = true
}


variable "enable_bastion" {
  description = "Enable deployment of the Azure Bastion host"
  type        = bool
  default     = true
}

variable "enable_bastion_automation" {
  description = "Enable Azure Automation runbooks that delete Bastion after hours and recreate it on weekdays or on demand"
  type        = bool
  default     = true
}

variable "bastion_sku" {
  description = "SKU for Azure Bastion. Standard or Premium is required for native tunneling."
  type        = string
  default     = "Standard"
}

variable "bastion_tunneling_enabled" {
  description = "Enable native client tunneling for Azure Bastion."
  type        = bool
  default     = true
}

variable "bastion_copy_paste_enabled" {
  description = "Enable copy and paste in Azure Bastion sessions."
  type        = bool
  default     = true
}

variable "bastion_file_copy_enabled" {
  description = "Enable file copy in Azure Bastion sessions."
  type        = bool
  default     = false
}

variable "bastion_ip_connect_enabled" {
  description = "Enable Azure Bastion IP Connect."
  type        = bool
  default     = false
}

variable "bastion_shareable_link_enabled" {
  description = "Enable Azure Bastion shareable links."
  type        = bool
  default     = false
}

variable "bastion_scale_units" {
  description = "Scale units to configure on the Azure Bastion host."
  type        = number
  default     = 2
}

variable "bastion_public_ip_sku" {
  description = "SKU for the Azure Bastion public IP."
  type        = string
  default     = "Standard"
}

variable "bastion_public_ip_sku_tier" {
  description = "SKU tier for the Azure Bastion public IP."
  type        = string
  default     = "Regional"
}

variable "bastion_public_ip_allocation_method" {
  description = "Allocation method for the Azure Bastion public IP."
  type        = string
  default     = "Static"
}

variable "bastion_public_ip_version" {
  description = "IP version for the Azure Bastion public IP."
  type        = string
  default     = "IPv4"
}

variable "bastion_public_ip_idle_timeout_in_minutes" {
  description = "Idle timeout in minutes for the Azure Bastion public IP."
  type        = number
  default     = 4
}

variable "bastion_public_ip_ddos_protection_mode" {
  description = "DDoS protection mode for the Azure Bastion public IP."
  type        = string
  default     = "VirtualNetworkInherited"
}

variable "enable_jumpbox" {
  description = "Enable deployment of the Azure Jumpbox VM"
  type        = bool
  default     = true
}

variable "enable_entra_login" {
  description = "Enable Microsoft Entra ID (AAD) SSH login on the Linux jumpbox VM"
  type        = bool
  default     = true
}

variable "vm_size" {
  description = "Size of the Linux jumpbox VM. Increase this to scale the single jumpbox vertically."
  type        = string
  default     = "Standard_B2als_v2"
}

variable "os_disk_type" {
  description = "Storage account type for the jumpbox OS disk. Standard SSD avoids the Standard HDD retirement path."
  type        = string
  default     = "StandardSSD_LRS"
}

variable "os_disk_size_gb" {
  description = "Size of the jumpbox OS disk in GB."
  type        = number
  default     = 64
}

### -----------------------------------------------------------------------------
### Log Analytics Variables
### -----------------------------------------------------------------------------
variable "log_analytics_retention_days" {
  description = "Number of days to retain data in Log Analytics Workspace"
  type        = number
  default     = 30
}

variable "log_analytics_sku" {
  description = "SKU for Log Analytics Workspace"
  type        = string
  default     = "PerGB2018"
}
