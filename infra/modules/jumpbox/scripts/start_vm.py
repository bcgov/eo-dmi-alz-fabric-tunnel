#!/usr/bin/env python3
"""Start the jumpbox VM from an Azure Automation runbook or local test harness.

The script uses the Automation Account managed identity endpoint to acquire an
ARM token, then issues a VM start request against the target jumpbox.
"""

import json
import os
import sys

# Environment variables let the checked-in script be run directly for ad hoc testing.
SUBSCRIPTION_ID = os.environ.get("SUBSCRIPTION_ID", "${subscription_id}")
RESOURCE_GROUP = os.environ.get("RESOURCE_GROUP", "${resource_group_name}")
VM_NAME = os.environ.get("VM_NAME", "${app_name}-jumpbox")


def get_automation_token():
    """Fetch an ARM access token from the Automation Account managed identity."""

    import urllib.error
    import urllib.request

    identity_endpoint = os.environ.get("IDENTITY_ENDPOINT")
    identity_header = os.environ.get("IDENTITY_HEADER")

    if not identity_endpoint or not identity_header:
        raise Exception(
            "IDENTITY_ENDPOINT or IDENTITY_HEADER not set. Ensure managed identity is enabled on the Automation Account."
        )

    token_url = f"{identity_endpoint}?resource=https://management.azure.com/&api-version=2019-08-01"
    request = urllib.request.Request(token_url)
    request.add_header("X-IDENTITY-HEADER", identity_header)
    request.add_header("Metadata", "true")

    try:
        response = urllib.request.urlopen(request, timeout=30)
        data = json.loads(response.read().decode())
        return data["access_token"]
    except urllib.error.HTTPError as exc:
        body = exc.read().decode() if exc.fp else ""
        raise Exception(f"Failed to get token: {exc.code} {exc.reason} - {body}")


def start_vm(access_token):
    """Send the Azure Resource Manager request that starts the jumpbox VM."""

    import urllib.error
    import urllib.request

    url = f"https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Compute/virtualMachines/{VM_NAME}/start?api-version=2023-07-01"
    request = urllib.request.Request(url, data=b"", method="POST")
    request.add_header("Authorization", f"Bearer {access_token}")
    request.add_header("Content-Type", "application/json")

    try:
        response = urllib.request.urlopen(request, timeout=60)
        print(f"VM start initiated successfully (status: {response.status})")
    except urllib.error.HTTPError as exc:
        if exc.code == 202:
            print("VM start initiated successfully (async operation - 202)")
            return
        body = exc.read().decode() if exc.fp else ""
        raise Exception(f"Failed to start VM: {exc.code} {exc.reason} - {body}")


def main():
    """Run the VM start workflow and surface failures as a non-zero exit."""

    try:
        print(f"Starting VM: {VM_NAME}")
        token = get_automation_token()
        start_vm(token)
    except Exception as exc:
        print(f"ERROR: {str(exc)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
