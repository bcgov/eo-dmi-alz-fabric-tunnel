#!/usr/bin/env python3
"""Create the Bastion host and its public IP from an Automation runbook.

The script supports both Terraform-rendered runbook execution and direct local
testing by allowing environment variables to override the rendered defaults.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

# Environment variables let the checked-in script be run directly for ad hoc testing.
SUBSCRIPTION_ID = os.environ.get("SUBSCRIPTION_ID", "${subscription_id}")
RESOURCE_GROUP = os.environ.get("RESOURCE_GROUP", "${resource_group_name}")
LOCATION = os.environ.get("LOCATION", "${location}")
BASTION_NAME = os.environ.get("BASTION_NAME", "${app_name}-bastion")
PUBLIC_IP_NAME = os.environ.get("PUBLIC_IP_NAME", "${app_name}-bastion-pip")
BASTION_SUBNET_ID = os.environ.get("BASTION_SUBNET_ID", "${bastion_subnet_id}")
BASTION_SKU = os.environ.get("BASTION_SKU", "${bastion_sku}")
COPY_PASTE_ENABLED = (
    os.environ.get("COPY_PASTE_ENABLED", "${bastion_copy_paste_enabled}").lower()
    == "true"
)
FILE_COPY_ENABLED = (
    os.environ.get("FILE_COPY_ENABLED", "${bastion_file_copy_enabled}").lower()
    == "true"
)
IP_CONNECT_ENABLED = (
    os.environ.get("IP_CONNECT_ENABLED", "${bastion_ip_connect_enabled}").lower()
    == "true"
)
SHAREABLE_LINK_ENABLED = (
    os.environ.get(
        "SHAREABLE_LINK_ENABLED", "${bastion_shareable_link_enabled}"
    ).lower()
    == "true"
)
SCALE_UNITS = int(os.environ.get("SCALE_UNITS", "${bastion_scale_units}"))
ENABLE_TUNNELING = (
    os.environ.get("ENABLE_TUNNELING", "${bastion_tunneling_enabled}").lower() == "true"
)
PUBLIC_IP_SKU = os.environ.get("PUBLIC_IP_SKU", "${bastion_public_ip_sku}")
PUBLIC_IP_SKU_TIER = os.environ.get(
    "PUBLIC_IP_SKU_TIER", "${bastion_public_ip_sku_tier}"
)
PUBLIC_IP_ALLOCATION_METHOD = os.environ.get(
    "PUBLIC_IP_ALLOCATION_METHOD", "${bastion_public_ip_allocation_method}"
)
PUBLIC_IP_VERSION = os.environ.get("PUBLIC_IP_VERSION", "${bastion_public_ip_version}")
PUBLIC_IP_IDLE_TIMEOUT_IN_MINUTES = int(
    os.environ.get(
        "PUBLIC_IP_IDLE_TIMEOUT_IN_MINUTES",
        "${bastion_public_ip_idle_timeout_in_minutes}",
    )
)
PUBLIC_IP_DDOS_PROTECTION_MODE = os.environ.get(
    "PUBLIC_IP_DDOS_PROTECTION_MODE",
    "${bastion_public_ip_ddos_protection_mode}",
)
TAGS = json.loads(os.environ.get("TAGS_JSON", r"""${common_tags_json}"""))
PUBLIC_IP_API_VERSION = "2023-09-01"
BASTION_API_VERSION = "2023-09-01"

PUBLIC_IP_URL = f"https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Network/publicIPAddresses/{PUBLIC_IP_NAME}?api-version={PUBLIC_IP_API_VERSION}"
BASTION_URL = f"https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Network/bastionHosts/{BASTION_NAME}?api-version={BASTION_API_VERSION}"
PUBLIC_IP_ID = f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Network/publicIPAddresses/{PUBLIC_IP_NAME}"


def get_automation_token():
    """Fetch an ARM access token from the Automation Account managed identity."""

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

    response = urllib.request.urlopen(request, timeout=30)
    data = json.loads(response.read().decode())
    return data["access_token"]


def arm_request(method, url, access_token, body=None):
    """Send an ARM request and return the HTTP status code and response body."""

    payload = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=payload, method=method)
    request.add_header("Authorization", f"Bearer {access_token}")
    request.add_header("Content-Type", "application/json")

    try:
        response = urllib.request.urlopen(request, timeout=60)
        response_body = response.read().decode() if response.length != 0 else ""
        return response.status, response_body
    except urllib.error.HTTPError as exc:
        response_body = exc.read().decode() if exc.fp else ""
        return exc.code, response_body


def ensure_success(status_code, response_body, allowed_codes, action_name):
    """Raise an error when an ARM operation returns an unexpected status code."""

    if status_code not in allowed_codes:
        raise Exception(f"{action_name} failed: HTTP {status_code} - {response_body}")


def wait_for_provisioning_state(
    url,
    access_token,
    resource_name,
    desired_state="Succeeded",
    timeout_seconds=900,
    deleted=False,
):
    """Poll a resource until it reaches the expected provisioning state or disappears."""

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
    raise Exception(
        f"Timed out waiting for {resource_name} to reach provisioningState={desired_state}"
    )


def ensure_public_ip(access_token):
    """Create the Bastion public IP if it does not already exist."""

    status_code, response_body = arm_request("GET", PUBLIC_IP_URL, access_token)
    if status_code == 200:
        print("Public IP already exists")
        return
    if status_code != 404:
        raise Exception(
            f"Failed to query Public IP: HTTP {status_code} - {response_body}"
        )

    payload = {
        "location": LOCATION,
        "sku": {"name": PUBLIC_IP_SKU, "tier": PUBLIC_IP_SKU_TIER},
        "properties": {
            "ddosSettings": {"protectionMode": PUBLIC_IP_DDOS_PROTECTION_MODE},
            "idleTimeoutInMinutes": PUBLIC_IP_IDLE_TIMEOUT_IN_MINUTES,
            "publicIPAddressVersion": PUBLIC_IP_VERSION,
            "publicIPAllocationMethod": PUBLIC_IP_ALLOCATION_METHOD,
        },
        "tags": TAGS,
    }

    status_code, response_body = arm_request(
        "PUT", PUBLIC_IP_URL, access_token, payload
    )
    ensure_success(status_code, response_body, {200, 201}, "Create Public IP")
    wait_for_provisioning_state(PUBLIC_IP_URL, access_token, "Public IP")


def ensure_bastion(access_token):
    """Create the Bastion host if it does not already exist."""

    status_code, response_body = arm_request("GET", BASTION_URL, access_token)
    if status_code == 200:
        print("Bastion host already exists")
        return
    if status_code != 404:
        raise Exception(
            f"Failed to query Bastion host: HTTP {status_code} - {response_body}"
        )

    payload = {
        "location": LOCATION,
        "sku": {"name": BASTION_SKU},
        "properties": {
            "disableCopyPaste": not COPY_PASTE_ENABLED,
            "enableFileCopy": FILE_COPY_ENABLED,
            "enableIpConnect": IP_CONNECT_ENABLED,
            "enableShareableLink": SHAREABLE_LINK_ENABLED,
            "enableTunneling": ENABLE_TUNNELING,
            "ipConfigurations": [
                {
                    "name": "configuration",
                    "properties": {
                        "privateIPAllocationMethod": "Dynamic",
                        "publicIPAddress": {"id": PUBLIC_IP_ID},
                        "subnet": {"id": BASTION_SUBNET_ID},
                    },
                }
            ],
            "scaleUnits": SCALE_UNITS,
        },
        "tags": TAGS,
    }

    status_code, response_body = arm_request("PUT", BASTION_URL, access_token, payload)
    ensure_success(status_code, response_body, {200, 201}, "Create Bastion host")
    wait_for_provisioning_state(BASTION_URL, access_token, "Bastion host")


def main():
    """Run the Bastion creation workflow and exit non-zero on failure."""

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
