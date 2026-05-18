#!/usr/bin/env python3
"""Start the jumpbox VM from an Azure Automation runbook or local test harness.

The script uses the Automation Account managed identity endpoint to acquire an
ARM token, then issues a VM start request against the target jumpbox.
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
VM_NAME = os.environ.get("VM_NAME", "${app_name}-jumpbox")
VM_API_VERSION = "2023-07-01"
TOKEN_REQUEST_TIMEOUT_SECONDS = int(
    os.environ.get("TOKEN_REQUEST_TIMEOUT_SECONDS", "30")
)
ARM_REQUEST_TIMEOUT_SECONDS = int(os.environ.get("ARM_REQUEST_TIMEOUT_SECONDS", "60"))
ARM_RETRY_ATTEMPTS = int(os.environ.get("ARM_RETRY_ATTEMPTS", "5"))
ARM_RETRY_BASE_DELAY_SECONDS = int(os.environ.get("ARM_RETRY_BASE_DELAY_SECONDS", "5"))
ARM_RETRY_MAX_DELAY_SECONDS = int(os.environ.get("ARM_RETRY_MAX_DELAY_SECONDS", "60"))
POLL_INTERVAL_SECONDS = int(os.environ.get("ARM_POLL_INTERVAL_SECONDS", "20"))
VM_START_TIMEOUT_SECONDS = int(os.environ.get("VM_START_TIMEOUT_SECONDS", "900"))
RETRYABLE_HTTP_STATUS_CODES = {408, 409, 423, 429, 500, 502, 503, 504}

VM_START_URL = f"https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Compute/virtualMachines/{VM_NAME}/start?api-version={VM_API_VERSION}"
VM_INSTANCE_VIEW_URL = f"https://management.azure.com/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.Compute/virtualMachines/{VM_NAME}/instanceView?api-version={VM_API_VERSION}"


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


def ensure_success(status_code, response_body, allowed_codes, action_name):
    """Raise when an ARM request returns an unexpected status code."""

    if status_code not in allowed_codes:
        raise Exception(f"{action_name} failed: HTTP {status_code} - {response_body}")


def arm_request(method, url, access_token, body=None):
    """Send an ARM request and return the HTTP status code and response body."""

    payload = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=payload, method=method)
    request.add_header("Authorization", f"Bearer {access_token}")
    request.add_header("Content-Type", "application/json")

    action_name = f"{method} {url.split('?')[0]}"
    return request_with_retry(request, ARM_REQUEST_TIMEOUT_SECONDS, action_name)


def get_vm_instance_state(response_body):
    """Extract VM provisioning and power states from an instanceView payload."""

    if not response_body:
        return None, None

    body = json.loads(response_body)
    provisioning_state = None
    power_state = None

    for status in body.get("statuses", []):
        code = status.get("code", "")
        if code.startswith("ProvisioningState/"):
            provisioning_state = code.split("/", 1)[1]
        elif code.startswith("PowerState/"):
            power_state = code.split("/", 1)[1]

    return provisioning_state, power_state


def get_vm_instance_view(access_token):
    """Fetch the VM instanceView and return its response for state inspection."""

    status_code, response_body = arm_request("GET", VM_INSTANCE_VIEW_URL, access_token)
    if status_code == 404:
        raise Exception(f"VM not found: {VM_NAME}")
    if status_code != 200:
        raise Exception(
            f"Failed to query VM instanceView: HTTP {status_code} - {response_body}"
        )

    return response_body


def wait_for_vm_power_state(access_token, desired_states, timeout_seconds):
    """Poll the VM instanceView until the power state reaches one of the desired values."""

    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        response_body = get_vm_instance_view(access_token)
        provisioning_state, power_state = get_vm_instance_state(response_body)
        print(f"VM provisioningState={provisioning_state}, powerState={power_state}")

        if provisioning_state == "failed":
            raise Exception(
                f"VM entered provisioningState=failed while waiting for power state: {response_body}"
            )

        if power_state in desired_states:
            return power_state

        time.sleep(POLL_INTERVAL_SECONDS)

    desired_states_display = ", ".join(sorted(desired_states))
    raise Exception(
        f"Timed out waiting for VM to reach powerState in {{{desired_states_display}}}"
    )


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


def ensure_vm_started(access_token):
    """Start the VM when needed and wait until it reaches the running power state."""

    response_body = get_vm_instance_view(access_token)
    provisioning_state, power_state = get_vm_instance_state(response_body)
    print(
        f"Current VM provisioningState={provisioning_state}, powerState={power_state}"
    )

    if provisioning_state == "failed":
        raise Exception(
            f"VM is in provisioningState=failed and cannot be started safely: {response_body}"
        )

    if power_state == "running":
        print("VM already running")
        return

    if power_state == "starting":
        print("VM already starting; waiting for it to reach running")
        wait_for_vm_power_state(access_token, {"running"}, VM_START_TIMEOUT_SECONDS)
        return

    if power_state in {"stopping", "deallocating"}:
        print(
            "VM is currently stopping or deallocating; waiting for it to settle before issuing start"
        )
        wait_for_vm_power_state(
            access_token,
            {"stopped", "deallocated"},
            VM_START_TIMEOUT_SECONDS,
        )

    status_code, response_body = arm_request("POST", VM_START_URL, access_token, {})
    ensure_success(
        status_code,
        response_body,
        {200, 202, 409},
        "Start VM",
    )
    print(f"VM start initiated successfully (status: {status_code})")
    wait_for_vm_power_state(access_token, {"running"}, VM_START_TIMEOUT_SECONDS)


def main():
    """Run the VM start workflow and surface failures as a non-zero exit."""

    try:
        print(f"Starting VM: {VM_NAME}")
        token = get_automation_token()
        ensure_vm_started(token)
    except Exception as exc:
        print(f"ERROR: {str(exc)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
