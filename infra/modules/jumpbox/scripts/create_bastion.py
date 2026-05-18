#!/usr/bin/env python3
"""Create the Bastion host and its public IP from an Automation runbook.

The script supports both Terraform-rendered runbook execution and direct local
testing by allowing environment variables to override the rendered defaults.
"""

import json
import os
import socket
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
TOKEN_REQUEST_TIMEOUT_SECONDS = int(
    os.environ.get("TOKEN_REQUEST_TIMEOUT_SECONDS", "30")
)
ARM_REQUEST_TIMEOUT_SECONDS = int(os.environ.get("ARM_REQUEST_TIMEOUT_SECONDS", "60"))
ARM_RETRY_ATTEMPTS = int(os.environ.get("ARM_RETRY_ATTEMPTS", "5"))
ARM_RETRY_BASE_DELAY_SECONDS = int(os.environ.get("ARM_RETRY_BASE_DELAY_SECONDS", "5"))
ARM_RETRY_MAX_DELAY_SECONDS = int(os.environ.get("ARM_RETRY_MAX_DELAY_SECONDS", "60"))
POLL_INTERVAL_SECONDS = int(os.environ.get("ARM_POLL_INTERVAL_SECONDS", "20"))
RETRYABLE_HTTP_STATUS_CODES = {408, 409, 423, 429, 500, 502, 503, 504}

PUBLIC_IP_URL = f"https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Network/publicIPAddresses/{PUBLIC_IP_NAME}?api-version={PUBLIC_IP_API_VERSION}"
BASTION_URL = f"https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Network/bastionHosts/{BASTION_NAME}?api-version={BASTION_API_VERSION}"
PUBLIC_IP_ID = f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Network/publicIPAddresses/{PUBLIC_IP_NAME}"


def get_retry_delay_seconds(attempt_number, retry_after_header=None):
    """Return a bounded retry delay, preferring Retry-After when present."""

    if retry_after_header:
        try:
            return max(1, min(int(retry_after_header), ARM_RETRY_MAX_DELAY_SECONDS))
        except ValueError:
            pass

    return min(
        ARM_RETRY_BASE_DELAY_SECONDS * (2**attempt_number),
        ARM_RETRY_MAX_DELAY_SECONDS,
    )


def perform_request(request, timeout_seconds):
    """Execute a single HTTP request and return status, body, and headers."""

    try:
        response = urllib.request.urlopen(request, timeout=timeout_seconds)
        response_body = response.read().decode() if response.length != 0 else ""
        return response.status, response_body, response.headers
    except urllib.error.HTTPError as exc:
        response_body = exc.read().decode() if exc.fp else ""
        return exc.code, response_body, exc.headers


def request_with_retry(request, timeout_seconds, action_name):
    """Retry recoverable HTTP and network errors with bounded backoff."""

    for attempt_number in range(ARM_RETRY_ATTEMPTS + 1):
        try:
            status_code, response_body, response_headers = perform_request(
                request, timeout_seconds
            )
        except (
            urllib.error.URLError,
            TimeoutError,
            ConnectionResetError,
            socket.timeout,
        ) as exc:
            if attempt_number >= ARM_RETRY_ATTEMPTS:
                raise Exception(
                    f"{action_name} failed after {ARM_RETRY_ATTEMPTS + 1} attempts: {exc}"
                ) from exc

            delay_seconds = get_retry_delay_seconds(attempt_number)
            print(
                f"{action_name} hit a recoverable network error ({exc}); retrying in {delay_seconds}s"
            )
            time.sleep(delay_seconds)
            continue

        if status_code not in RETRYABLE_HTTP_STATUS_CODES:
            return status_code, response_body

        if attempt_number >= ARM_RETRY_ATTEMPTS:
            return status_code, response_body

        delay_seconds = get_retry_delay_seconds(
            attempt_number, response_headers.get("Retry-After")
        )
        print(
            f"{action_name} returned recoverable HTTP {status_code}; retrying in {delay_seconds}s"
        )
        time.sleep(delay_seconds)

    raise Exception(f"{action_name} exhausted retry handling unexpectedly")


def get_provisioning_state(response_body):
    """Extract the ARM provisioning state from a JSON response body."""

    if not response_body:
        return None

    body = json.loads(response_body)
    return body.get("properties", {}).get("provisioningState")


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

    status_code, response_body = request_with_retry(
        request,
        TOKEN_REQUEST_TIMEOUT_SECONDS,
        "Fetch automation token",
    )
    ensure_success(status_code, response_body, {200}, "Fetch automation token")
    data = json.loads(response_body)
    return data["access_token"]


def arm_request(method, url, access_token, body=None):
    """Send an ARM request and return the HTTP status code and response body."""

    payload = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=payload, method=method)
    request.add_header("Authorization", f"Bearer {access_token}")
    request.add_header("Content-Type", "application/json")

    action_name = f"{method} {url.split('?')[0]}"
    return request_with_retry(request, ARM_REQUEST_TIMEOUT_SECONDS, action_name)


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
            provisioning_state = get_provisioning_state(response_body)
            print(f"{resource_name} provisioningState={provisioning_state}")
            if provisioning_state == "Failed":
                raise Exception(
                    f"{resource_name} entered provisioningState=Failed: {response_body}"
                )
            if provisioning_state == desired_state:
                return
        elif status_code not in {200, 404}:
            raise Exception(
                f"Unexpected GET response while polling {resource_name}: HTTP {status_code} - {response_body}"
            )

        time.sleep(POLL_INTERVAL_SECONDS)

    if deleted:
        raise Exception(f"Timed out waiting for {resource_name} to be deleted")
    raise Exception(
        f"Timed out waiting for {resource_name} to reach provisioningState={desired_state}"
    )


def ensure_public_ip(access_token):
    """Create the Bastion public IP if it does not already exist."""

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

    while True:
        status_code, response_body = arm_request("GET", PUBLIC_IP_URL, access_token)
        if status_code == 200:
            provisioning_state = get_provisioning_state(response_body)
            if provisioning_state == "Succeeded":
                print("Public IP already exists")
                return

            if provisioning_state == "Deleting":
                print(
                    "Public IP deletion already in progress; waiting for it to finish"
                )
                wait_for_provisioning_state(
                    PUBLIC_IP_URL,
                    access_token,
                    "Public IP",
                    deleted=True,
                )
                continue

            if provisioning_state in {"Creating", "Updating"}:
                print("Public IP already exists and is still provisioning")
                wait_for_provisioning_state(PUBLIC_IP_URL, access_token, "Public IP")
                return

            print(
                f"Public IP exists with provisioningState={provisioning_state}; reconciling desired configuration"
            )
        elif status_code != 404:
            raise Exception(
                f"Failed to query Public IP: HTTP {status_code} - {response_body}"
            )

        status_code, response_body = arm_request(
            "PUT", PUBLIC_IP_URL, access_token, payload
        )
        ensure_success(status_code, response_body, {200, 201, 202}, "Create Public IP")
        wait_for_provisioning_state(PUBLIC_IP_URL, access_token, "Public IP")
        return


def ensure_bastion(access_token):
    """Create the Bastion host if it does not already exist."""

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

    while True:
        status_code, response_body = arm_request("GET", BASTION_URL, access_token)
        if status_code == 200:
            provisioning_state = get_provisioning_state(response_body)
            if provisioning_state == "Succeeded":
                print("Bastion host already exists")
                return

            if provisioning_state == "Deleting":
                print(
                    "Bastion host deletion already in progress; waiting for it to finish"
                )
                wait_for_provisioning_state(
                    BASTION_URL,
                    access_token,
                    "Bastion host",
                    deleted=True,
                )
                continue

            if provisioning_state in {"Creating", "Updating"}:
                print("Bastion host already exists and is still provisioning")
                wait_for_provisioning_state(BASTION_URL, access_token, "Bastion host")
                return

            print(
                f"Bastion host exists with provisioningState={provisioning_state}; reconciling desired configuration"
            )
        elif status_code != 404:
            raise Exception(
                f"Failed to query Bastion host: HTTP {status_code} - {response_body}"
            )

        status_code, response_body = arm_request(
            "PUT", BASTION_URL, access_token, payload
        )
        ensure_success(
            status_code,
            response_body,
            {200, 201, 202},
            "Create Bastion host",
        )
        wait_for_provisioning_state(BASTION_URL, access_token, "Bastion host")
        return


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
