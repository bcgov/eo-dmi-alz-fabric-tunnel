# -----------------------------------------------------------------------------
# Azure Linux VM (Jumpbox/Tunnel) Module
# -----------------------------------------------------------------------------
# Creates a minimal Linux VM used only as an Azure Bastion SOCKS tunnel endpoint.
# Authentication is through Microsoft Entra ID SSH login; no SSH key pair is
# generated or written locally.
# -----------------------------------------------------------------------------

resource "random_string" "admin_username" {
  length  = 12
  upper   = true
  lower   = true
  special = false
}

data "azurerm_subscription" "current" {}

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

  network_interface_ids = [
    azurerm_network_interface.jumpbox.id,
  ]

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

  tags = var.common_tags
  lifecycle {
    ignore_changes = [
      tags,
      identity
    ]
  }
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "jumpbox" {
  virtual_machine_id    = azurerm_linux_virtual_machine.jumpbox.id
  location              = var.location
  enabled               = true
  daily_recurrence_time = "1900"
  timezone              = "Pacific Standard Time"

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

resource "azurerm_automation_runbook" "start_vm" {
  name                    = "Start-JumpboxVM"
  location                = var.location
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.jumpbox.name
  log_verbose             = false
  log_progress            = false
  runbook_type            = "Python3"

  content = <<-PYTHON
#!/usr/bin/env python3
import json
import os
import sys

SUBSCRIPTION_ID = "${data.azurerm_subscription.current.subscription_id}"
RESOURCE_GROUP = "${var.resource_group_name}"
VM_NAME = "${var.app_name}-jumpbox"

def get_automation_token():
    import urllib.error
    import urllib.request

    identity_endpoint = os.environ.get("IDENTITY_ENDPOINT")
    identity_header = os.environ.get("IDENTITY_HEADER")

    if not identity_endpoint or not identity_header:
        raise Exception("IDENTITY_ENDPOINT or IDENTITY_HEADER not set. Ensure managed identity is enabled on the Automation Account.")

    token_url = f"{identity_endpoint}?resource=https://management.azure.com/&api-version=2019-08-01"
    req = urllib.request.Request(token_url)
    req.add_header("X-IDENTITY-HEADER", identity_header)
    req.add_header("Metadata", "true")

    try:
        response = urllib.request.urlopen(req, timeout=30)
        data = json.loads(response.read().decode())
        return data["access_token"]
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ""
        raise Exception(f"Failed to get token: {e.code} {e.reason} - {body}")

def start_vm(access_token):
    import urllib.error
    import urllib.request

    url = f"https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Compute/virtualMachines/{VM_NAME}/start?api-version=2023-07-01"
    req = urllib.request.Request(url, data=b"", method="POST")
    req.add_header("Authorization", f"Bearer {access_token}")
    req.add_header("Content-Type", "application/json")

    try:
        response = urllib.request.urlopen(req, timeout=60)
        print(f"VM start initiated successfully (status: {response.status})")
    except urllib.error.HTTPError as e:
        if e.code == 202:
            print("VM start initiated successfully (async operation - 202)")
            return
        body = e.read().decode() if e.fp else ""
        raise Exception(f"Failed to start VM: {e.code} {e.reason} - {body}")

def main():
    try:
        print(f"Starting VM: {VM_NAME}")
        token = get_automation_token()
        start_vm(token)
    except Exception as e:
        print(f"ERROR: {str(e)}")
        sys.exit(1)

if __name__ == "__main__":
    main()
  PYTHON

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags, runbook_type]
  }
}

resource "azurerm_automation_schedule" "weekday_start" {
  name                    = "Weekday-8AM-Start"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.jumpbox.name
  frequency               = "Week"
  interval                = 1
  timezone                = "America/Vancouver"
  start_time              = "${formatdate("YYYY-MM-DD", timeadd(timestamp(), "24h"))}T08:00:00Z"
  week_days               = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]

  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_job_schedule" "start_vm" {
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.jumpbox.name
  schedule_name           = azurerm_automation_schedule.weekday_start.name
  runbook_name            = azurerm_automation_runbook.start_vm.name
}

resource "azurerm_role_assignment" "automation_vm_contributor" {
  scope                = azurerm_linux_virtual_machine.jumpbox.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_automation_account.jumpbox.identity[0].principal_id
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

resource "azurerm_role_assignment" "vm_admin_login" {
  for_each = var.enable_entra_login ? toset(var.vm_admin_login_principal_ids) : toset([])

  scope                = azurerm_linux_virtual_machine.jumpbox.id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = each.value
}

