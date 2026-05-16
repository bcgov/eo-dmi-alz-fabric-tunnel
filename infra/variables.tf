
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



### -----------------------------------------------------------------------------
### Azure Proxy Module Variables
### -----------------------------------------------------------------------------
variable "azure_proxy_image" {
  description = "The image for the Azure Proxy container"
  type        = string
}
variable "app_service_sku_name_azure_proxy" {
  description = "The SKU name for the azure proxy App Service plan."
  type        = string
  default     = "P0v4"
}
variable "enable_azure_proxy" {
  description = "Enable deployment of the Azure Proxy App Service"
  type        = bool
  default     = false
}


variable "enable_bastion" {
  description = "Enable deployment of the Azure Bastion host"
  type        = bool
  default     = false
}
variable "enable_jumpbox" {
  description = "Enable deployment of the Azure Jumpbox VM"
  type        = bool
  default     = false
}

variable "enable_entra_login" {
  description = "Enable Microsoft Entra ID (AAD) SSH login on the jumpbox VM"
  type        = bool
  default     = true
}

variable "vm_admin_login_principal_ids" {
  description = "List of Entra group or user object IDs to grant Virtual Machine Administrator Login role on the jumpbox"
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for id in var.vm_admin_login_principal_ids :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))
    ])
    error_message = "All entries in vm_admin_login_principal_ids must be valid GUIDs (e.g. 033ec9ae-c728-42ae-8b40-0ca8fe777133)."
  }
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
