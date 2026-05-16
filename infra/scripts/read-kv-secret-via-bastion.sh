#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: read-kv-secret-via-bastion.sh \
  --resource-group <resource-group> \
  --key-vault-resource-group <key-vault-resource-group> \
  --key-vault-name <key-vault-name> \
  --secret-name <secret-name>

This script discovers the Bastion host and jumpbox VM in the resource group,
opens an Azure Bastion native SSH session with Microsoft Entra authentication,
creates a local SOCKS proxy over that session, reads the requested Key Vault
secret through the proxy, and prints only the last two characters of the secret
value.
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || fail "Required command not found: $command_name"
}

wait_for_port() {
  local host="$1"
  local port="$2"
  local timeout_seconds="$3"
  local start_time
  start_time=$(date +%s)

  while true; do
    if (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      return 0
    fi

    if (( $(date +%s) - start_time >= timeout_seconds )); then
      return 1
    fi

    sleep 2
  done
}

discover_single_resource_field() {
  local resource_group="$1"
  local resource_type="$2"
  local field_name="$3"
  local description="$4"
  local matches=()
  local value

  while IFS= read -r value; do
    if [[ -n "$value" ]]; then
      matches+=("$value")
    fi
  done < <(az resource list \
    --resource-group "$resource_group" \
    --resource-type "$resource_type" \
    --query "[].${field_name}" \
    --output tsv)

  if [[ ${#matches[@]} -eq 0 ]]; then
    fail "No ${description} found in resource group ${resource_group}"
  fi

  if [[ ${#matches[@]} -gt 1 ]]; then
    printf '[ERROR] Multiple %s values found in %s:\n' "$description" "$resource_group" >&2
    printf '  %s\n' "${matches[@]}" >&2
    exit 1
  fi

  printf '%s' "${matches[0]}"
}

RESOURCE_GROUP=""
KEY_VAULT_RESOURCE_GROUP=""
KEY_VAULT_NAME=""
SECRET_NAME=""
SOCKS_PORT="58228"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)
      RESOURCE_GROUP="$2"
      shift 2
      ;;
    --key-vault-resource-group)
      KEY_VAULT_RESOURCE_GROUP="$2"
      shift 2
      ;;
    --key-vault-name)
      KEY_VAULT_NAME="$2"
      shift 2
      ;;
    --secret-name)
      SECRET_NAME="$2"
      shift 2
      ;;
    --socks-port)
      SOCKS_PORT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$RESOURCE_GROUP" ]] || fail "--resource-group is required"
[[ -n "$KEY_VAULT_RESOURCE_GROUP" ]] || fail "--key-vault-resource-group is required"
[[ -n "$KEY_VAULT_NAME" ]] || fail "--key-vault-name is required"
[[ -n "$SECRET_NAME" ]] || fail "--secret-name is required"

require_command az
require_command ssh
require_command curl
require_command jq

if [[ -z "${AZURE_EXTENSION_DIR:-}" ]]; then
  AZURE_EXTENSION_DIR="${HOME}/.azure/cliextensions-bastion-secret-read"
  export AZURE_EXTENSION_DIR
fi
mkdir -p "$AZURE_EXTENSION_DIR"

AAD_SSH_LOG=$(mktemp)
RESPONSE_FILE=$(mktemp)

cleanup() {
  if [[ -n "${AAD_SSH_PID:-}" ]] && kill -0 "$AAD_SSH_PID" >/dev/null 2>&1; then
    kill "$AAD_SSH_PID" >/dev/null 2>&1 || true
    wait "$AAD_SSH_PID" 2>/dev/null || true
  fi

  rm -f "$AAD_SSH_LOG" "$RESPONSE_FILE"
}

trap cleanup EXIT

log "Ensuring Azure Bastion CLI extensions are available"
az extension add --name bastion --upgrade --only-show-errors >/dev/null
az extension add --name ssh --upgrade --only-show-errors >/dev/null

BASTION_NAME=$(discover_single_resource_field "$RESOURCE_GROUP" "Microsoft.Network/bastionHosts" "name" "Bastion host")
VM_ID=$(discover_single_resource_field "$RESOURCE_GROUP" "Microsoft.Compute/virtualMachines" "id" "virtual machine")
VM_NAME=$(discover_single_resource_field "$RESOURCE_GROUP" "Microsoft.Compute/virtualMachines" "name" "virtual machine")

log "Using Bastion host: ${BASTION_NAME}"
log "Using jumpbox VM: ${VM_NAME}"
log "Using Key Vault resource group: ${KEY_VAULT_RESOURCE_GROUP}"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=30
  -N
  -D "127.0.0.1:${SOCKS_PORT}"
)

log "Starting Azure Bastion AAD SOCKS proxy on localhost:${SOCKS_PORT}"
# Git Bash/MSYS rewrites arguments that look like Unix paths when calling
# Windows executables. Azure resource IDs begin with /subscriptions/... and
# must be passed through unchanged.
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' az network bastion ssh \
  --name "$BASTION_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --target-resource-id "$VM_ID" \
  --auth-type AAD \
  -- "${SSH_OPTS[@]}" > "$AAD_SSH_LOG" 2>&1 &
AAD_SSH_PID=$!

wait_for_port 127.0.0.1 "$SOCKS_PORT" 60 || {
  cat "$AAD_SSH_LOG" >&2 || true
  fail "Azure Bastion AAD SOCKS proxy did not become ready"
}

ACCESS_TOKEN=$(az account get-access-token --resource https://vault.azure.net --query accessToken --output tsv)
[[ -n "$ACCESS_TOKEN" ]] || fail "Failed to acquire a Key Vault access token"

SECRET_URL="https://${KEY_VAULT_NAME}.vault.azure.net/secrets/${SECRET_NAME}?api-version=7.5"

HTTP_CODE=$(curl -sS \
  --socks5-hostname "127.0.0.1:${SOCKS_PORT}" \
  -o "$RESPONSE_FILE" \
  -w '%{http_code}' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "$SECRET_URL")

if [[ "$HTTP_CODE" != "200" ]]; then
  cat "$RESPONSE_FILE" >&2 || true
  fail "Key Vault secret read failed with HTTP ${HTTP_CODE}"
fi

SECRET_VALUE=$(jq -r '.value' "$RESPONSE_FILE")
[[ -n "$SECRET_VALUE" && "$SECRET_VALUE" != "null" ]] || fail "Secret value is empty or missing"

if (( ${#SECRET_VALUE} >= 2 )); then
  LAST_TWO_CHARACTERS="${SECRET_VALUE: -2}"
else
  LAST_TWO_CHARACTERS="$SECRET_VALUE"
fi

printf 'SUCCESS: secret read through Bastion tunnel. Last 2 characters: %s\n' "$LAST_TWO_CHARACTERS"