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

  # Keep the private key in Terraform state for break-glass retrieval, but do
  # not write it to disk.
  response_export_values = ["publicKey", "privateKey"]
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

resource "azurerm_automation_runbook" "create_bastion" {
  count                   = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  name                    = "Create-BastionHost"
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
  import time
  import urllib.error
  import urllib.request

  SUBSCRIPTION_ID = "${data.azurerm_subscription.current.subscription_id}"
  RESOURCE_GROUP = "${var.resource_group_name}"
  LOCATION = "${var.location}"
  BASTION_NAME = "${var.app_name}-bastion"
  PUBLIC_IP_NAME = "${var.app_name}-bastion-pip"
  BASTION_SUBNET_ID = "${var.bastion_subnet_id}"
  BASTION_SKU = "${var.bastion_sku}"
  ENABLE_TUNNELING = ${var.bastion_tunneling_enabled ? "True" : "False"}
  TAGS = json.loads(r'''${jsonencode(var.common_tags)}''')
  PUBLIC_IP_API_VERSION = "2023-09-01"
  BASTION_API_VERSION = "2023-09-01"

  PUBLIC_IP_URL = f"https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Network/publicIPAddresses/{PUBLIC_IP_NAME}?api-version={PUBLIC_IP_API_VERSION}"
  BASTION_URL = f"https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Network/bastionHosts/{BASTION_NAME}?api-version={BASTION_API_VERSION}"
  PUBLIC_IP_ID = f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Network/publicIPAddresses/{PUBLIC_IP_NAME}"

  def get_automation_token():
    identity_endpoint = os.environ.get("IDENTITY_ENDPOINT")
    identity_header = os.environ.get("IDENTITY_HEADER")

    if not identity_endpoint or not identity_header:
      raise Exception("IDENTITY_ENDPOINT or IDENTITY_HEADER not set. Ensure managed identity is enabled on the Automation Account.")

    token_url = f"{identity_endpoint}?resource=https://management.azure.com/&api-version=2019-08-01"
    req = urllib.request.Request(token_url)
    req.add_header("X-IDENTITY-HEADER", identity_header)
    req.add_header("Metadata", "true")

    response = urllib.request.urlopen(req, timeout=30)
    data = json.loads(response.read().decode())
    return data["access_token"]

  def arm_request(method, url, access_token, body=None):
    payload = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=payload, method=method)
    req.add_header("Authorization", f"Bearer {access_token}")
    req.add_header("Content-Type", "application/json")

    try:
      response = urllib.request.urlopen(req, timeout=60)
      response_body = response.read().decode() if response.length != 0 else ""
      return response.status, response_body
    except urllib.error.HTTPError as exc:
      response_body = exc.read().decode() if exc.fp else ""
      return exc.code, response_body

  def ensure_success(status_code, response_body, allowed_codes, action_name):
    if status_code not in allowed_codes:
      raise Exception(f"{action_name} failed: HTTP {status_code} - {response_body}")

  def wait_for_provisioning_state(url, access_token, resource_name, desired_state="Succeeded", timeout_seconds=900, deleted=False):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
      status_code, response_body = arm_request("GET", url, access_token)
      if deleted:
        if status_code == 404:
          print(f"{resource_name} deletion confirmed")
          return
      elif status_code == 200:
        body = json.loads(response_body) if response_body else {}
        provisioning_state = body.get("properties", {}).get("provisioningState")
        print(f"{resource_name} provisioningState={provisioning_state}")
        if provisioning_state == desired_state:
          return
      time.sleep(20)

    if deleted:
      raise Exception(f"Timed out waiting for {resource_name} to be deleted")
    raise Exception(f"Timed out waiting for {resource_name} to reach provisioningState={desired_state}")

  def ensure_public_ip(access_token):
    status_code, response_body = arm_request("GET", PUBLIC_IP_URL, access_token)
    if status_code == 200:
      print("Public IP already exists")
      return
    if status_code != 404:
      raise Exception(f"Failed to query Public IP: HTTP {status_code} - {response_body}")

    payload = {
      "location": LOCATION,
      "sku": {
        "name": "Standard",
        "tier": "Regional"
      },
      "properties": {
        "ddosSettings": {
          "protectionMode": "VirtualNetworkInherited"
        },
        "idleTimeoutInMinutes": 4,
        "publicIPAddressVersion": "IPv4",
        "publicIPAllocationMethod": "Static"
      },
      "tags": TAGS
    }

    status_code, response_body = arm_request("PUT", PUBLIC_IP_URL, access_token, payload)
    ensure_success(status_code, response_body, {200, 201}, "Create Public IP")
    wait_for_provisioning_state(PUBLIC_IP_URL, access_token, "Public IP")

  def ensure_bastion(access_token):
    status_code, response_body = arm_request("GET", BASTION_URL, access_token)
    if status_code == 200:
      print("Bastion host already exists")
      return
    if status_code != 404:
      raise Exception(f"Failed to query Bastion host: HTTP {status_code} - {response_body}")

    payload = {
      "location": LOCATION,
      "sku": {
        "name": BASTION_SKU
      },
      "properties": {
        "disableCopyPaste": False,
        "enableFileCopy": False,
        "enableIpConnect": False,
        "enableShareableLink": False,
        "enableTunneling": ENABLE_TUNNELING,
        "ipConfigurations": [
          {
            "name": "configuration",
            "properties": {
              "privateIPAllocationMethod": "Dynamic",
              "publicIPAddress": {
                "id": PUBLIC_IP_ID
              },
              "subnet": {
                "id": BASTION_SUBNET_ID
              }
            }
          }
        ],
        "scaleUnits": 2
      },
      "tags": TAGS
    }

    status_code, response_body = arm_request("PUT", BASTION_URL, access_token, payload)
    ensure_success(status_code, response_body, {200, 201}, "Create Bastion host")
    wait_for_provisioning_state(BASTION_URL, access_token, "Bastion host")

  def main():
    try:
      print(f"Ensuring Bastion host exists: {BASTION_NAME}")
      token = get_automation_token()
      ensure_public_ip(token)
      ensure_bastion(token)
      print("Bastion host is ready")
    except Exception as exc:
      print(f"ERROR: {str(exc)}")
      sys.exit(1)

  if __name__ == "__main__":
    main()
    PYTHON

  tags = var.common_tags
  lifecycle {
    ignore_changes = [tags, runbook_type]
  }
}

resource "azurerm_automation_runbook" "delete_bastion" {
  count                   = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  name                    = "Delete-BastionHost"
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
  import time
  import urllib.error
  import urllib.request

  SUBSCRIPTION_ID = "${data.azurerm_subscription.current.subscription_id}"
  RESOURCE_GROUP = "${var.resource_group_name}"
  BASTION_NAME = "${var.app_name}-bastion"
  PUBLIC_IP_NAME = "${var.app_name}-bastion-pip"
  PUBLIC_IP_API_VERSION = "2023-09-01"
  BASTION_API_VERSION = "2023-09-01"

  PUBLIC_IP_URL = f"https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Network/publicIPAddresses/{PUBLIC_IP_NAME}?api-version={PUBLIC_IP_API_VERSION}"
  BASTION_URL = f"https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Network/bastionHosts/{BASTION_NAME}?api-version={BASTION_API_VERSION}"

  def get_automation_token():
    identity_endpoint = os.environ.get("IDENTITY_ENDPOINT")
    identity_header = os.environ.get("IDENTITY_HEADER")

    if not identity_endpoint or not identity_header:
      raise Exception("IDENTITY_ENDPOINT or IDENTITY_HEADER not set. Ensure managed identity is enabled on the Automation Account.")

    token_url = f"{identity_endpoint}?resource=https://management.azure.com/&api-version=2019-08-01"
    req = urllib.request.Request(token_url)
    req.add_header("X-IDENTITY-HEADER", identity_header)
    req.add_header("Metadata", "true")

    response = urllib.request.urlopen(req, timeout=30)
    data = json.loads(response.read().decode())
    return data["access_token"]

  def arm_request(method, url, access_token, body=None):
    payload = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=payload, method=method)
    req.add_header("Authorization", f"Bearer {access_token}")
    req.add_header("Content-Type", "application/json")

    try:
      response = urllib.request.urlopen(req, timeout=60)
      response_body = response.read().decode() if response.length != 0 else ""
      return response.status, response_body
    except urllib.error.HTTPError as exc:
      response_body = exc.read().decode() if exc.fp else ""
      return exc.code, response_body

  def ensure_success(status_code, response_body, allowed_codes, action_name):
    if status_code not in allowed_codes:
      raise Exception(f"{action_name} failed: HTTP {status_code} - {response_body}")

  def wait_for_deletion(url, access_token, resource_name, timeout_seconds=900):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
      status_code, response_body = arm_request("GET", url, access_token)
      if status_code == 404:
        print(f"{resource_name} deletion confirmed")
        return
      if status_code not in {200, 404}:
        raise Exception(f"Unexpected GET response while waiting for {resource_name} deletion: HTTP {status_code} - {response_body}")
      time.sleep(20)

    raise Exception(f"Timed out waiting for {resource_name} to be deleted")

  def delete_if_present(url, access_token, resource_name):
    status_code, response_body = arm_request("GET", url, access_token)
    if status_code == 404:
      print(f"{resource_name} already absent")
      return
    if status_code != 200:
      raise Exception(f"Failed to query {resource_name}: HTTP {status_code} - {response_body}")

    status_code, response_body = arm_request("DELETE", url, access_token)
    ensure_success(status_code, response_body, {200, 202, 204}, f"Delete {resource_name}")
    wait_for_deletion(url, access_token, resource_name)

  def main():
    try:
      print(f"Deleting Bastion host if present: {BASTION_NAME}")
      token = get_automation_token()
      delete_if_present(BASTION_URL, token, "Bastion host")
      delete_if_present(PUBLIC_IP_URL, token, "Bastion public IP")
      print("Bastion host and public IP are absent")
    except Exception as exc:
      print(f"ERROR: {str(exc)}")
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

resource "azurerm_automation_schedule" "weekday_create_bastion" {
  count                   = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  name                    = "Weekday-8AM-Create-Bastion"
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

resource "azurerm_automation_job_schedule" "create_bastion" {
  count                   = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.jumpbox.name
  schedule_name           = azurerm_automation_schedule.weekday_create_bastion[0].name
  runbook_name            = azurerm_automation_runbook.create_bastion[0].name
}

resource "azurerm_automation_schedule" "daily_delete_bastion" {
  count                   = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  name                    = "Daily-7PM-Delete-Bastion"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.jumpbox.name
  frequency               = "Day"
  interval                = 1
  timezone                = "America/Vancouver"
  start_time              = "${formatdate("YYYY-MM-DD", timeadd(timestamp(), "24h"))}T19:00:00Z"

  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_job_schedule" "delete_bastion" {
  count                   = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.jumpbox.name
  schedule_name           = azurerm_automation_schedule.daily_delete_bastion[0].name
  runbook_name            = azurerm_automation_runbook.delete_bastion[0].name
}

resource "azurerm_role_assignment" "automation_network_contributor" {
  count                = var.enable_bastion && var.enable_bastion_automation ? 1 : 0
  scope                = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_automation_account.jumpbox.identity[0].principal_id
}

resource "azurerm_role_assignment" "automation_bastion_subnet_network_contributor" {
  count                = var.enable_bastion && var.enable_bastion_automation && var.bastion_subnet_id != null ? 1 : 0
  scope                = var.bastion_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_automation_account.jumpbox.identity[0].principal_id
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

