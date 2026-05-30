# -----------------------------------------------------------------------------
# Azure Linux VM (Jumpbox/Tunnel) Module
# -----------------------------------------------------------------------------
# Creates a minimal Linux VM used only as an Azure Bastion SOCKS tunnel endpoint.
# Authentication is through Microsoft Entra ID SSH login. AzureRM still requires
# a bootstrap SSH public key for VM creation, but no private key is written locally.
# -----------------------------------------------------------------------------

resource "random_string" "admin_username" {
  length  = 12
  upper   = true
  lower   = true
  special = false
}

data "azurerm_subscription" "current" {}

# AzureRM requires at least one admin_ssh_key when password auth is disabled.
# The key is used only to satisfy VM creation; developer access stays Entra-only.
resource "azapi_resource" "bootstrap_ssh_public_key" {
  type      = "Microsoft.Compute/sshPublicKeys@2022-11-01"
  name      = "${var.app_name}-jumpbox-bootstrap-ssh-key"
  location  = var.location
  parent_id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"

  body = {}

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azapi_resource_action" "bootstrap_ssh_keypair" {
  type        = "Microsoft.Compute/sshPublicKeys@2022-11-01"
  resource_id = azapi_resource.bootstrap_ssh_public_key.id
  action      = "generateKeyPair"
  method      = "POST"

  response_export_values = ["publicKey"]
}

resource "azurerm_network_interface" "jumpbox" {
  name                = "${var.app_name}-jumpbox-nic"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                            = "${var.app_name}-jumpbox"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = random_string.admin_username.result
  disable_password_authentication = true
  priority                        = "Regular"
  provision_vm_agent              = true
  patch_mode                      = "AutomaticByPlatform"
  patch_assessment_mode           = "AutomaticByPlatform"
  reboot_setting                  = "IfRequired"

  network_interface_ids = [
    azurerm_network_interface.jumpbox.id,
  ]

  admin_ssh_key {
    username   = random_string.admin_username.result
    public_key = azapi_resource_action.bootstrap_ssh_keypair.output.publicKey
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  # Keep platform guest patching and Update Manager assessment enabled to meet
  # ALZ guardrail expectations for VM compliance visibility.

  tags = var.common_tags
  lifecycle {
    ignore_changes = [
      tags,
      admin_ssh_key
    ]
  }
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "jumpbox" {
  virtual_machine_id    = azurerm_linux_virtual_machine.jumpbox.id
  location              = var.location
  enabled               = true
  daily_recurrence_time = "0100" # 6 PM Pacific with the repo's +7 offset becomes 01:00 UTC the next day
  timezone              = "UTC"

  notification_settings {
    enabled = false
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_automation_account" "jumpbox" {
  name                = "${var.app_name}-jumpbox-automation"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Basic"

  identity {
    type = "SystemAssigned"
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azapi_resource" "python310" {
  type      = "Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23"
  parent_id = azurerm_automation_account.jumpbox.id
  name      = "python310-runtime"
  location  = var.location

  body = {
    properties = {
      description = "Python 3.10 runtime for runbooks"
      runtime = {
        language = "Python"
        version  = "3.10"
      }
    }
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_automation_runbook" "start_vm" {
  name                     = "Start-JumpboxVM"
  location                 = var.location
  resource_group_name      = var.resource_group_name
  automation_account_name  = azurerm_automation_account.jumpbox.name
  log_verbose              = true
  log_progress             = true
  runbook_type             = "Python"
  runtime_environment_name = azapi_resource.python310.name

  content = templatefile("${path.module}/scripts/start_vm.py", {
    subscription_id     = data.azurerm_subscription.current.subscription_id
    resource_group_name = var.resource_group_name
    app_name            = var.app_name
  })

  job_schedule {
    schedule_name = azurerm_automation_schedule.weekday_start.name
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_automation_runbook" "create_bastion" {
  count                    = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  name                     = "Create-BastionHost"
  location                 = var.location
  resource_group_name      = var.resource_group_name
  automation_account_name  = azurerm_automation_account.jumpbox.name
  log_verbose              = true
  log_progress             = true
  runbook_type             = "Python"
  runtime_environment_name = azapi_resource.python310.name


  content = templatefile("${path.module}/scripts/create_bastion.py", {
    subscription_id                           = data.azurerm_subscription.current.subscription_id
    resource_group_name                       = var.resource_group_name
    location                                  = var.location
    app_name                                  = var.app_name
    bastion_subnet_id                         = coalesce(var.bastion_subnet_id, "")
    bastion_sku                               = var.bastion_sku
    bastion_tunneling_enabled                 = tostring(var.bastion_tunneling_enabled)
    bastion_copy_paste_enabled                = tostring(var.bastion_copy_paste_enabled)
    bastion_file_copy_enabled                 = tostring(var.bastion_file_copy_enabled)
    bastion_ip_connect_enabled                = tostring(var.bastion_ip_connect_enabled)
    bastion_shareable_link_enabled            = tostring(var.bastion_shareable_link_enabled)
    bastion_scale_units                       = tostring(var.bastion_scale_units)
    bastion_public_ip_sku                     = var.bastion_public_ip_sku
    bastion_public_ip_sku_tier                = var.bastion_public_ip_sku_tier
    bastion_public_ip_allocation_method       = var.bastion_public_ip_allocation_method
    bastion_public_ip_version                 = var.bastion_public_ip_version
    bastion_public_ip_idle_timeout_in_minutes = tostring(var.bastion_public_ip_idle_timeout_in_minutes)
    bastion_public_ip_ddos_protection_mode    = var.bastion_public_ip_ddos_protection_mode
    common_tags_json                          = jsonencode(var.common_tags)
  })

  job_schedule {
    schedule_name = azurerm_automation_schedule.weekday_create_bastion[0].name
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_automation_runbook" "delete_bastion" {
  count                    = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  name                     = "Delete-BastionHost"
  location                 = var.location
  resource_group_name      = var.resource_group_name
  automation_account_name  = azurerm_automation_account.jumpbox.name
  log_verbose              = true
  log_progress             = true
  runbook_type             = "Python"
  runtime_environment_name = azapi_resource.python310.name

  content = templatefile("${path.module}/scripts/delete_bastion.py", {
    subscription_id     = data.azurerm_subscription.current.subscription_id
    resource_group_name = var.resource_group_name
    app_name            = var.app_name
  })

  job_schedule {
    schedule_name = azurerm_automation_schedule.daily_delete_bastion[0].name
  }

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

locals {
  automation_schedule_timezone             = "UTC"
  automation_weekday_start_time_utc        = "16:00:00Z"
  automation_daily_delete_bastion_time_utc = "01:00:00Z"
}

resource "azurerm_automation_schedule" "weekday_start" {
  name                    = "Weekday-1600UTC-Start"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.jumpbox.name
  frequency               = "Week"
  interval                = 1
  timezone                = local.automation_schedule_timezone
  start_time              = "${formatdate("YYYY-MM-DD", timeadd(timestamp(), "24h"))}T${local.automation_weekday_start_time_utc}"
  week_days               = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]

  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_schedule" "weekday_create_bastion" {
  count                   = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  name                    = "Weekday-1600UTC-Create-Bastion"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.jumpbox.name
  frequency               = "Week"
  interval                = 1
  timezone                = local.automation_schedule_timezone
  start_time              = "${formatdate("YYYY-MM-DD", timeadd(timestamp(), "24h"))}T${local.automation_weekday_start_time_utc}"
  week_days               = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]

  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_schedule" "daily_delete_bastion" {
  count                   = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  name                    = "Daily-0100UTC-Delete-Bastion"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.jumpbox.name
  frequency               = "Day"
  interval                = 1
  timezone                = local.automation_schedule_timezone
  start_time              = "${formatdate("YYYY-MM-DD", timeadd(timestamp(), "24h"))}T${local.automation_daily_delete_bastion_time_utc}"

  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_role_assignment" "automation_network_contributor" {
  count                = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  scope                = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_automation_account.jumpbox.identity[0].principal_id
}

resource "azurerm_role_assignment" "automation_bastion_subnet_network_contributor" {
  count = var.enable_bastion && var.enable_bastion_automation && var.bastion_subnet_id != null && trimspace(var.bastion_subnet_id) != "" ? 1 : 0

  scope                = var.bastion_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_automation_account.jumpbox.identity[0].principal_id
  lifecycle {
    precondition {
      condition     = var.bastion_subnet_id != null
      error_message = "bastion_subnet_id must be provided when bastion automation is enabled."
    }
  }
}

resource "azurerm_role_assignment" "automation_vm_contributor" {
  scope                = azurerm_linux_virtual_machine.jumpbox.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_automation_account.jumpbox.identity[0].principal_id
}

resource "azurerm_role_assignment" "vm_admin_login" {
  for_each = toset(var.vm_admin_login_principal_ids)

  scope                = azurerm_linux_virtual_machine.jumpbox.id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = each.value
}

resource "azurerm_virtual_machine_extension" "aad_ssh_login" {
  count = var.enable_entra_login ? 1 : 0

  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.jumpbox.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags]
  }
}

