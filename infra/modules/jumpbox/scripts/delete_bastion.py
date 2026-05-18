#!/usr/bin/env python3
"""Delete the Bastion host and its public IP from an Automation runbook.

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
BASTION_NAME = os.environ.get("BASTION_NAME", "${app_name}-bastion")
PUBLIC_IP_NAME = os.environ.get("PUBLIC_IP_NAME", "${app_name}-bastion-pip")
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


def wait_for_deletion(url, access_token, resource_name, timeout_seconds=900):
    """Poll until the target ARM resource returns 404, confirming deletion."""

    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        status_code, response_body = arm_request("GET", url, access_token)
        if status_code == 404:
            print(f"{resource_name} deletion confirmed")
            return
        if status_code not in {200, 404}:
            raise Exception(
                f"Unexpected GET response while waiting for {resource_name} deletion: HTTP {status_code} - {response_body}"
            )
        provisioning_state = get_provisioning_state(response_body)
        if provisioning_state:
            print(f"{resource_name} provisioningState={provisioning_state}")
        time.sleep(POLL_INTERVAL_SECONDS)

    raise Exception(f"Timed out waiting for {resource_name} to be deleted")


def delete_if_present(url, access_token, resource_name):
    """Delete the target resource when it exists and wait for completion."""

    status_code, response_body = arm_request("GET", url, access_token)
    if status_code == 404:
        print(f"{resource_name} already absent")
        return
    if status_code != 200:
        raise Exception(
            f"Failed to query {resource_name}: HTTP {status_code} - {response_body}"
        )

    provisioning_state = get_provisioning_state(response_body)
    if provisioning_state == "Deleting":
        print(f"{resource_name} deletion already in progress")
        wait_for_deletion(url, access_token, resource_name)
        return

    status_code, response_body = arm_request("DELETE", url, access_token)
    ensure_success(
        status_code, response_body, {200, 202, 204, 404}, f"Delete {resource_name}"
    )
    wait_for_deletion(url, access_token, resource_name)


def main():
    """Run the Bastion deletion workflow and exit non-zero on failure."""

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
