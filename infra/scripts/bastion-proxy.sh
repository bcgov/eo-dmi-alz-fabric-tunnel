#!/usr/bin/env bash
# =============================================================================
# bastion-proxy.sh — SOCKS5 proxy via Azure Bastion
# =============================================================================
#
# Creates a SOCKS5 proxy on your local machine by tunnelling through Azure
# Bastion to the jumpbox VM. All traffic routed through the proxy is resolved
# and forwarded by the jumpbox, giving access to private PaaS endpoints
# without a VPN.
#
# A single SOCKS5 port can forward traffic to ANY hostname the jumpbox can
# reach (CosmosDB, PostgreSQL, Redis, Azure OpenAI, AI Search, etc.).
# No per-service configuration is needed. See the jumpbox README for tool
# usage examples.
#
# PREREQUISITES
#   Azure CLI:         installed automatically if missing when supported by the host OS
#   bastion extension: installed automatically if missing
#   ssh extension:     installed automatically if missing (AAD auth only)
#   Standard SKU Azure Bastion with native tunnelling enabled
#   The signing-in Entra user, or a group they belong to, must have
#   a manual "Virtual Machine Administrator Login" assignment on the
#   Linux jumpbox VM (AAD auth)
#
# AUTHENTICATION
#   Uses Azure CLI Entra browser login with MFA in the BC Gov tenant by default.
#   Entra login alone is not enough; the authenticated user must also be
#   authorized on the Linux VM through a manual VM login RBAC assignment.
#
# USAGE
#   ./scripts/bastion-proxy.sh -g <resource-group> -b <bastion-name> -v <vm-name>
#
# OPTIONS
#   -g, --resource-group    Resource group containing Bastion and VM   [required]
#   -b, --bastion-name      Name of the Azure Bastion host             [required]
#   -v, --vm-name           Name of the jumpbox VM                     [required]
#   -s, --subscription      Azure subscription ID to use               [default: built-in repo default]
#   -p, --port              Starting SOCKS5 port (default: 8228)       [optional]
#   -h, --help              Show this help and exit
#
# EXAMPLES
#   # Entra ID (AAD) auth:
#   ./scripts/bastion-proxy.sh -g <resource-group> -b <bastion-name> -v <vm-name>
#
#   # Override the active Azure subscription if needed:
#   ./scripts/bastion-proxy.sh -g <resource-group> -b <bastion-name> -v <vm-name> -s <subscription-id>
#
#   # Example for this repo deployment:
#   ./scripts/bastion-proxy.sh -s ffc5e617-7f2d-4ddb-8b57-33fc43989a8c -g eo-dmi-alz-bastion-jumpbox-tools -b eo-dmi-alz-bastion-jumpbox-bastion -v eo-dmi-alz-bastion-jumpbox-jumpbox
#
#   # Derive names from Terraform outputs (run from initial-setup/infra/):
#   ./scripts/bastion-proxy.sh \
#     -g "$(terraform output -raw resource_group_name)" \
#     -b "$(terraform output -raw jumpbox_vm_name | sed 's/-jumpbox$/-bastion/')" \
#     -v "$(terraform output -raw jumpbox_vm_name)"
#
# =============================================================================

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────

DEFAULT_SOCKS_PORT=8228
DEFAULT_SUBSCRIPTION_ID="ffc5e617-7f2d-4ddb-8b57-33fc43989a8c"
DEFAULT_TENANT_ID="6fdb5200-3d0d-4a8a-b036-d3685e359adc"

# ── Colours (only when writing to a terminal) ─────────────────────────────────

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

err()  { printf '%b%s\n' "${RED}[ERROR]${RESET} " "$*" >&2; }
info() { printf '%b%s\n' "${CYAN}[INFO]${RESET}  " "$*"; }
ok()   { printf '%b%s\n' "${GREEN}[ OK ]${RESET}  " "$*"; }
warn() { printf '%b%s\n' "${YELLOW}[WARN]${RESET}  " "$*"; }
trim_cr() { tr -d '\r'; }
command_exists() { command -v "$1" &>/dev/null; }

AZ_PROBE_OUTPUT=""

az_probe() {
  local output=""
  local exit_code=0

  set +e
  output=$("$@" 2>&1)
  exit_code=$?
  set -e

  AZ_PROBE_OUTPUT=$(printf '%s' "$output" | trim_cr)
  return "$exit_code"
}

get_az_failure_text() {
  local exit_code=${1:-1}

  if [[ -n "$AZ_PROBE_OUTPUT" ]]; then
    printf '%s\n' "$AZ_PROBE_OUTPUT"
    return 0
  fi

  printf 'Azure CLI exited with code %s.\n' "$exit_code"
}

print_az_output() {
  local log_function=$1
  local message_text=$2

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    "$log_function" "$line"
  done <<< "$message_text"
}

print_az_failure() {
  local exit_code=${1:-1}
  print_az_output err "$(get_az_failure_text "$exit_code")"
}

print_az_warning() {
  local exit_code=${1:-1}
  print_az_output warn "$(get_az_failure_text "$exit_code")"
}

should_retry_az_failure() {
  [[ "$AZ_PROBE_OUTPUT" == *"ConnectionResetError"* ]] \
    || [[ "$AZ_PROBE_OUTPUT" == *"Connection aborted"* ]] \
    || [[ "$AZ_PROBE_OUTPUT" == *"RemoteDisconnected"* ]] \
    || [[ "$AZ_PROBE_OUTPUT" == *"temporarily unavailable"* ]]
}

az_probe_with_retry() {
  local max_attempts=$1
  local delay_seconds=$2
  local attempt=1
  local exit_code=0
  shift 2

  while true; do
    if az_probe "$@"; then
      return 0
    fi

    exit_code=$?
    if ! should_retry_az_failure || (( attempt >= max_attempts )); then
      return "$exit_code"
    fi

    warn "Azure CLI command failed with a transient connection error. Retrying in ${delay_seconds}s (attempt ${attempt}/${max_attempts})..."
    sleep "$delay_seconds"
    attempt=$((attempt + 1))
  done
}

detect_os() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux) echo "linux" ;;
    Darwin) echo "macos" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) echo "unknown" ;;
  esac
}

windows_path_to_unix() {
  local input=$1

  if command_exists cygpath; then
    cygpath -u "$input"
    return 0
  fi

  if [[ "$input" =~ ^([A-Za-z]):[\\/](.*)$ ]]; then
    local drive
    local rest
    drive=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
    rest=${BASH_REMATCH[2]//\\//}
    printf '/%s/%s\n' "$drive" "$rest"
    return 0
  fi

  printf '%s\n' "$input"
}

unix_path_to_windows() {
  local input=$1

  if command_exists cygpath; then
    cygpath -w "$input"
    return 0
  fi

  if [[ "$input" =~ ^/([A-Za-z])/(.*)$ ]]; then
    local drive
    local rest
    drive=$(echo "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')
    rest=${BASH_REMATCH[2]//\//\\}
    printf '%s:\\%s\n' "$drive" "$rest"
    return 0
  fi

  printf '%s\n' "$input"
}

run_with_privilege() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    err "This Azure CLI install path requires sudo."
    return 1
  fi
}

install_azure_cli_windows() {
  local winget_cmd=""
  local choco_cmd=""

  winget_cmd=$(command -v winget.exe 2>/dev/null || command -v winget 2>/dev/null || true)
  choco_cmd=$(command -v choco.exe 2>/dev/null || command -v choco 2>/dev/null || true)

  if [[ -n "$winget_cmd" ]]; then
    info "Installing Azure CLI with WinGet..."
    "$winget_cmd" install --exact --id Microsoft.AzureCLI --accept-source-agreements --accept-package-agreements || warn "WinGet returned a non-zero exit code while installing Azure CLI."
    return 0
  fi

  if [[ -n "$choco_cmd" ]]; then
    info "Installing Azure CLI with Chocolatey..."
    "$choco_cmd" install azure-cli -y || warn "Chocolatey returned a non-zero exit code while installing Azure CLI."
    return 0
  fi

  if command_exists powershell.exe; then
    info "Installing Azure CLI with the Microsoft MSI installer..."
    powershell.exe -NoProfile -Command '& {
      $ProgressPreference = "SilentlyContinue"
      $installer = Join-Path $env:TEMP "AzureCLI.msi"
      Invoke-WebRequest -UseBasicParsing -Uri "https://aka.ms/installazurecliwindows" -OutFile $installer
      try {
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/i", $installer, "/passive", "/norestart") -Wait -PassThru
        if ($process.ExitCode -notin @(0, 3010)) {
          exit $process.ExitCode
        }
      }
      finally {
        Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
      }
    }' || warn "The MSI installer returned a non-zero exit code while installing Azure CLI."
    return 0
  fi

  err "Azure CLI could not be installed automatically on Windows. Install it from https://learn.microsoft.com/cli/azure/install-azure-cli"
  return 1
}

install_azure_cli_linux() {
  if command_exists apt-get; then
    info "Installing Azure CLI for Debian/Ubuntu..."
    if ! command_exists curl; then
      err "curl is required to install Azure CLI on Debian/Ubuntu."
      return 1
    fi

    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      curl -sL https://aka.ms/InstallAzureCLIDeb | bash
    elif command_exists sudo; then
      curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    else
      err "Installing Azure CLI on Debian/Ubuntu requires sudo."
      return 1
    fi
    return 0
  fi

  if command_exists dnf || command_exists yum; then
    local repo_file=""
    repo_file=$(mktemp)
    cat > "$repo_file" <<'EOF'
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

    info "Installing Azure CLI for RHEL/Fedora..."
    run_with_privilege rpm --import https://packages.microsoft.com/keys/microsoft.asc
    run_with_privilege mv "$repo_file" /etc/yum.repos.d/azure-cli.repo
    if command_exists dnf; then
      run_with_privilege dnf install -y azure-cli
    else
      run_with_privilege yum install -y azure-cli
    fi
    return 0
  fi

  err "Automatic Azure CLI install is not implemented for this Linux distribution. Install it from https://learn.microsoft.com/cli/azure/install-azure-cli"
  return 1
}

install_azure_cli() {
  case "$(detect_os)" in
    windows)
      install_azure_cli_windows
      ;;
    macos)
      if command_exists brew; then
        info "Installing Azure CLI with Homebrew..."
        brew install azure-cli
      else
        err "Homebrew is required for automatic Azure CLI install on macOS. Install Azure CLI from https://learn.microsoft.com/cli/azure/install-azure-cli"
        return 1
      fi
      ;;
    linux)
      install_azure_cli_linux
      ;;
    *)
      err "Automatic Azure CLI install is not supported on this operating system."
      return 1
      ;;
  esac
}

find_az_command() {
  local resolved=""

  resolved=$(type -P az 2>/dev/null || true)
  if [[ -n "$resolved" ]]; then
    echo "$resolved"
    return 0
  fi

  if [[ "$(detect_os)" == "windows" ]] && command_exists powershell.exe; then
    resolved=$(powershell.exe -NoProfile -Command '& {
      $azCommand = Get-Command az -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($azCommand) {
        foreach ($propertyName in @("Path", "Source", "Definition")) {
          $propertyValue = $azCommand.$propertyName
          if ($propertyValue) {
            Write-Output $propertyValue
            exit 0
          }
        }
      }
      $candidatePaths = @(
        (Join-Path $env:LocalAppData "Microsoft\WinGet\Links\az.cmd"),
        (Join-Path $env:LocalAppData "Microsoft\WinGet\Links\az.exe"),
        (Join-Path $env:ProgramFiles "Microsoft SDKs\Azure\CLI2\wbin\az.cmd"),
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft SDKs\Azure\CLI2\wbin\az.cmd"),
        (Join-Path $env:ProgramFiles "Microsoft SDKs\Azure\CLI2\wbin\az.ps1"),
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft SDKs\Azure\CLI2\wbin\az.ps1")
      ) | Where-Object { $_ }
      foreach ($candidatePath in $candidatePaths) {
        if (Test-Path $candidatePath) {
          Write-Output $candidatePath
          exit 0
        }
      }
      exit 1
    }' 2>/dev/null | trim_cr)
    if [[ -n "$resolved" ]]; then
      echo "$(windows_path_to_unix "$resolved")"
      return 0
    fi
  fi

  return 1
}

set_azure_extension_dir() {
  local extension_dir_input=$1

  AZURE_EXTENSION_DIR_FS="$extension_dir_input"
  AZURE_EXTENSION_DIR_CLI="$extension_dir_input"

  if [[ "$(detect_os)" == "windows" ]]; then
    if [[ "$extension_dir_input" =~ ^[A-Za-z]:[\\/].*$ ]]; then
      AZURE_EXTENSION_DIR_FS=$(windows_path_to_unix "$extension_dir_input")
    fi
    AZURE_EXTENSION_DIR_CLI=$(unix_path_to_windows "$AZURE_EXTENSION_DIR_FS")
  fi

  export AZURE_EXTENSION_DIR="$AZURE_EXTENSION_DIR_CLI"
}

new_az_extension_cache_path() {
  local temp_root="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"
  mktemp -d "${temp_root%/}/cliextensions-bastion-proxy.XXXXXX"
}

test_az_extension_cache() {
  local extension_name=""
  local extension_path=""
  local metadata_path=""

  shopt -s nullglob

  for extension_name in bastion ssh; do
    extension_path="${AZURE_EXTENSION_DIR_FS%/}/${extension_name}"
    if [[ ! -e "$extension_path" ]]; then
      continue
    fi

    if ! find "$extension_path" -maxdepth 1 -mindepth 1 -print >/dev/null 2>&1; then
      AZ_PROBE_OUTPUT="Azure CLI extension cache path '$extension_path' is not readable."
      shopt -u nullglob
      return 1
    fi

    for metadata_path in "$extension_path"/azext_*/azext_metadata.json "$extension_path"/*.dist-info; do
      if [[ ! -r "$metadata_path" ]]; then
        AZ_PROBE_OUTPUT="Azure CLI extension cache path '$metadata_path' is not readable."
        shopt -u nullglob
        return 1
      fi

      if [[ -d "$metadata_path" ]] && ! ls "$metadata_path" >/dev/null 2>&1; then
        AZ_PROBE_OUTPUT="Azure CLI extension cache path '$metadata_path' is not readable."
        shopt -u nullglob
        return 1
      fi
    done
  done

  shopt -u nullglob
  return 0
}

ensure_azure_extension_dir() {
  local extension_dir_input="${AZURE_EXTENSION_DIR:-${HOME}/.azure/cliextensions-bastion-proxy}"
  local cache_probe_exit_code=0
  local failed_path=""
  local fallback_dir=""

  set_azure_extension_dir "$extension_dir_input"
  mkdir -p "$AZURE_EXTENSION_DIR_FS"
  info "Using dedicated Azure CLI extension cache: ${AZURE_EXTENSION_DIR}"

  if test_az_extension_cache; then
    return 0
  fi

  cache_probe_exit_code=$?
  failed_path="$AZURE_EXTENSION_DIR"
  fallback_dir=$(new_az_extension_cache_path)

  warn "Azure CLI extension cache '${failed_path}' is unavailable. Using fresh cache '$(unix_path_to_windows "$fallback_dir")' for this run."
  print_az_warning "$cache_probe_exit_code"

  set_azure_extension_dir "$fallback_dir"
  mkdir -p "$AZURE_EXTENSION_DIR_FS"

  if ! test_az_extension_cache; then
    cache_probe_exit_code=$?
    err "Azure CLI extension cache could not be initialized."
    print_az_failure "$cache_probe_exit_code"
    exit 1
  fi
}

install_az_extension_if_missing() {
  local extension_name=$1
  local installed_name=""
  local probe_exit_code=0

  if ! az_probe az extension list --only-show-errors --query "[?name=='${extension_name}'].name | [0]" --output tsv; then
    probe_exit_code=$?
    err "Azure CLI could not inspect installed extensions in '${AZURE_EXTENSION_DIR}'."
    print_az_failure "$probe_exit_code"
    exit 1
  fi

  installed_name="$AZ_PROBE_OUTPUT"
  if [[ "$installed_name" == "$extension_name" ]]; then
    return 0
  fi

  info "Installing Azure CLI '${extension_name}' extension. This can take a minute on first use of a fresh cache."
  if ! az_probe az extension add --name "$extension_name" --yes --only-show-errors; then
    probe_exit_code=$?
    err "Azure CLI '${extension_name}' extension could not be installed."
    print_az_failure "$probe_exit_code"
    exit 1
  fi

  if ! az_probe az extension list --only-show-errors --query "[?name=='${extension_name}'].name | [0]" --output tsv; then
    probe_exit_code=$?
    err "Azure CLI '${extension_name}' extension could not be validated after installation."
    print_az_failure "$probe_exit_code"
    exit 1
  fi

  installed_name="$AZ_PROBE_OUTPUT"
  if [[ "$installed_name" != "$extension_name" ]]; then
    err "Azure CLI '${extension_name}' extension could not be installed."
    exit 1
  fi
}

AZ_COMMAND=""
AZURE_EXTENSION_DIR_FS=""
AZURE_EXTENSION_DIR_CLI=""

az() {
  "$AZ_COMMAND" "$@"
}

launch_proxy_browser() {
  local port=$1
  local browser_name=""
  local browser_cmd=""
  local tmp_root="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"
  local profile_dir=""

  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*)
      if command -v powershell.exe &>/dev/null; then
        browser_name=$(BASTION_PROXY_PORT="$port" powershell.exe -NoProfile -Command '& {
          $candidates = @(
            @{
              Name = "Edge"
              Paths = @(
                (Join-Path $env:LocalAppData "Microsoft\Edge\Application\msedge.exe"),
                (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"),
                (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe")
              )
            },
            @{
              Name = "Chrome"
              Paths = @(
                (Join-Path $env:LocalAppData "Google\Chrome\Application\chrome.exe"),
                (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
                (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe")
              )
            }
          )
          $browser = $null
          foreach ($candidate in $candidates) {
            foreach ($path in $candidate.Paths) {
              if ($path -and (Test-Path $path)) {
                $browser = [pscustomobject]@{ Name = $candidate.Name; Path = $path }
                break
              }
            }
            if ($browser) { break }
          }
          if (-not $browser) { exit 3 }
          $profileDir = Join-Path $env:TEMP ("bastion-proxy-" + $browser.Name.ToLowerInvariant())
          New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
          $arguments = @(
            "--new-window",
            "--proxy-server=socks5://127.0.0.1:$env:BASTION_PROXY_PORT",
            "--user-data-dir=$profileDir",
            "--no-first-run",
            "about:blank"
          )
          Start-Process -FilePath $browser.Path -ArgumentList $arguments | Out-Null
          Write-Output $browser.Name
        }' 2>/dev/null | tr -d '\r')

        if [[ -n "$browser_name" ]]; then
          ok "Opened ${browser_name} with SOCKS5 proxy localhost:${port}"
          return 0
        fi
      fi

      warn "Edge and Chrome were not found. Skipping automatic browser launch."
      return 0
      ;;
  esac

  if command -v microsoft-edge &>/dev/null; then
    browser_name="Edge"
    browser_cmd=$(command -v microsoft-edge)
  elif command -v microsoft-edge-stable &>/dev/null; then
    browser_name="Edge"
    browser_cmd=$(command -v microsoft-edge-stable)
  elif command -v google-chrome &>/dev/null; then
    browser_name="Chrome"
    browser_cmd=$(command -v google-chrome)
  elif command -v google-chrome-stable &>/dev/null; then
    browser_name="Chrome"
    browser_cmd=$(command -v google-chrome-stable)
  elif command -v chromium-browser &>/dev/null; then
    browser_name="Chrome"
    browser_cmd=$(command -v chromium-browser)
  fi

  if [[ -z "$browser_cmd" ]]; then
    warn "Edge and Chrome were not found. Skipping automatic browser launch."
    return 0
  fi

  profile_dir="${tmp_root}/bastion-proxy-${browser_name,,}"
  mkdir -p "$profile_dir"
  "$browser_cmd" \
    --new-window \
    "--proxy-server=socks5://127.0.0.1:${port}" \
    "--user-data-dir=${profile_dir}" \
    --no-first-run \
    about:blank >/dev/null 2>&1 &
  ok "Opened ${browser_name} with SOCKS5 proxy localhost:${port}"
}

usage() {
  sed -n '/^# USAGE/,/^# =/p' "$0" | sed 's/^# \?//' | sed '/^=\{5,\}/d'
  exit 0
}

# ── Port utilities ────────────────────────────────────────────────────────────

is_port_in_use() {
  local port=$1
  if [[ "$(detect_os)" == "windows" ]] && command -v netstat &>/dev/null; then
    netstat -ano 2>/dev/null | tr -d '\r' | grep -qE "TCP[[:space:]]+[0-9.:]+:${port}[[:space:]]+[0-9.:]+[[:space:]]+LISTENING"
  elif command -v ss &>/dev/null; then
    ss -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]"
  elif command -v lsof &>/dev/null; then
    lsof -iTCP:"$port" -sTCP:LISTEN &>/dev/null
  else
    nc -z 127.0.0.1 "$port" &>/dev/null
  fi
}

find_free_port() {
  local port=$1
  local limit=$((port + 50))
  while [[ $port -le $limit ]]; do
    if ! is_port_in_use "$port"; then
      echo "$port"
      return 0
    fi
    port=$((port + 1))
  done
  err "No free port found in range $1–$limit"
  exit 1
}

# ── Argument defaults ─────────────────────────────────────────────────────────

RESOURCE_GROUP=""
BASTION_NAME=""
VM_NAME=""
SUBSCRIPTION_ID="$DEFAULT_SUBSCRIPTION_ID"
START_PORT=$DEFAULT_SOCKS_PORT

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    -b|--bastion-name)   BASTION_NAME="$2";   shift 2 ;;
    -v|--vm-name)        VM_NAME="$2";        shift 2 ;;
    -s|--subscription)   SUBSCRIPTION_ID="$2"; shift 2 ;;
    -p|--port)           START_PORT="$2";     shift 2 ;;
    -h|--help)           usage ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Validate arguments ────────────────────────────────────────────────────────

[[ -z "$RESOURCE_GROUP" ]] && { err "--resource-group (-g) is required"; exit 1; }
[[ -z "$BASTION_NAME" ]]   && { err "--bastion-name (-b) is required";   exit 1; }
[[ -z "$VM_NAME" ]]        && { err "--vm-name (-v) is required";        exit 1; }

# ── Prerequisite checks ───────────────────────────────────────────────────────

info "Checking prerequisites..."
AZ_COMMAND=$(find_az_command || true)
if [[ -z "$AZ_COMMAND" ]]; then
  warn "Azure CLI (az) is not installed. Attempting installation..."
  install_azure_cli || exit 1
  AZ_COMMAND=$(find_az_command || true)
fi

if [[ -z "$AZ_COMMAND" ]]; then
  err "Azure CLI could not be resolved after installation. Re-run the script in a fresh shell or install it manually from https://learn.microsoft.com/cli/azure/install-azure-cli"
  exit 1
fi

info "Azure CLI ready: ${AZ_COMMAND}"

ensure_azure_extension_dir
install_az_extension_if_missing bastion
install_az_extension_if_missing ssh

ok "Prerequisites satisfied"

# ── Authentication ────────────────────────────────────────────────────────────

info "Checking Azure CLI login status for tenant ${DEFAULT_TENANT_ID}..."
if ! az account show &>/dev/null 2>&1; then
  echo ""
  info "Not logged in. Starting Entra browser authentication..."
  echo ""
  warn "Complete the MFA prompt in the browser window opened by Azure CLI for tenant ${DEFAULT_TENANT_ID}."
  echo ""
  az login --tenant "$DEFAULT_TENANT_ID"
  az account show &>/dev/null 2>&1 || { err "Azure CLI login did not complete successfully."; exit 1; }
else
  CURRENT_TENANT_ID=$(az account show --query tenantId --output tsv | trim_cr)
  if [[ -n "$CURRENT_TENANT_ID" && "$CURRENT_TENANT_ID" != "$DEFAULT_TENANT_ID" ]]; then
    echo ""
    warn "Azure CLI is currently using tenant ${CURRENT_TENANT_ID}. Re-authenticating with BC Gov tenant ${DEFAULT_TENANT_ID}..."
    echo ""
    az login --tenant "$DEFAULT_TENANT_ID"
    az account show &>/dev/null 2>&1 || { err "Azure CLI login did not complete successfully."; exit 1; }
  fi
  warn "Already logged in. Azure CLI sessions expire 12h after Azure CLI login."
  warn "Re-run this script if you encounter authentication errors."
fi

CURRENT_TENANT_ID=$(az account show --query tenantId --output tsv | trim_cr)
[[ "$CURRENT_TENANT_ID" == "$DEFAULT_TENANT_ID" ]] || { err "Azure CLI is not using the BC Gov tenant ${DEFAULT_TENANT_ID}."; exit 1; }

# Record authentication time and compute the 12h Entra ID session expiry.
# If already logged in, LOGIN_EPOCH is set to now (the original login time
# is not exposed by az CLI). Watch for auth errors if usage approaches 12h.
LOGIN_EPOCH=$(date +%s)
EXPIRE_EPOCH=$((LOGIN_EPOCH + 43200))
LOGIN_AT=$(date -d  "@${LOGIN_EPOCH}"  "+%H:%M %Z" 2>/dev/null \
        || date -r  "${LOGIN_EPOCH}"    "+%H:%M %Z" 2>/dev/null \
        || date                         "+%H:%M %Z")
EXPIRE_AT=$(date -d "@${EXPIRE_EPOCH}" "+%H:%M %Z" 2>/dev/null \
         || date -r  "${EXPIRE_EPOCH}"  "+%H:%M %Z" 2>/dev/null \
         || echo "12h from now")

ok "Authenticated to Azure CLI (tenant ${CURRENT_TENANT_ID})"

# ── Subscription ──────────────────────────────────────────────────────────────

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  info "Switching to subscription ${SUBSCRIPTION_ID}..."
  az account set --subscription "$SUBSCRIPTION_ID"
else
  SUBSCRIPTION_ID=$(az account show --query id --output tsv | trim_cr)
  info "Using current Azure subscription..."
fi
SUBSCRIPTION_NAME=$(az account show --query name --output tsv | trim_cr)
ok "Using: ${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})"

# ── Resolve VM resource ID ────────────────────────────────────────────────────

info "Resolving VM '${VM_NAME}' in resource group '${RESOURCE_GROUP}'..."
if ! az_probe_with_retry 3 3 az vm show \
  --only-show-errors \
  --name "$VM_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query id \
  --output tsv; then
  err "Failed to resolve VM '${VM_NAME}' in resource group '${RESOURCE_GROUP}'."
  print_az_failure "$?"
  exit 1
fi

VM_ID="$AZ_PROBE_OUTPUT"
if [[ -z "$VM_ID" ]]; then
  err "VM '${VM_NAME}' not found in resource group '${RESOURCE_GROUP}'"
  exit 1
fi
ok "VM found"

# ── VM running check ──────────────────────────────────────────────────────────

if ! az_probe_with_retry 3 3 az vm get-instance-view \
  --only-show-errors \
  --name "$VM_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "instanceView.statuses[?contains(code,'PowerState')].displayStatus | [0]" \
  --output tsv; then
  err "Failed to query VM power state for '${VM_NAME}'."
  print_az_failure "$?"
  exit 1
fi

VM_STATE="$AZ_PROBE_OUTPUT"

if [[ "$VM_STATE" != "VM running" ]]; then
  warn "VM is not running (current state: ${VM_STATE:-unknown})"
  read -rp "  Start the VM now? [y/N]: " START_VM
  if [[ "${START_VM,,}" == "y" ]]; then
    info "Starting VM..."
    az vm start --name "$VM_NAME" --resource-group "$RESOURCE_GROUP"
    info "Waiting for VM to reach running state..."
    az vm wait \
      --name "$VM_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --custom "instanceView.statuses[?code=='PowerState/running']"
    ok "VM is running"
  else
    err "VM must be running to create a proxy tunnel. Exiting."
    exit 1
  fi
fi

# ── Bastion health check ──────────────────────────────────────────────────────

info "Checking Bastion host '${BASTION_NAME}'..."
if ! az_probe_with_retry 3 3 az network bastion show \
  --only-show-errors \
  --name "$BASTION_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "provisioningState" \
  --output tsv; then
  err "Failed to query Bastion host '${BASTION_NAME}' in resource group '${RESOURCE_GROUP}'."
  print_az_failure "$?"
  exit 1
fi

BASTION_STATE="$AZ_PROBE_OUTPUT"

case "$BASTION_STATE" in
  Succeeded)
    ok "Bastion is ready"
    ;;
  Updating|Creating)
    info "Bastion is provisioning (state: ${BASTION_STATE}). Waiting..."
    while true; do
      sleep 15
      if ! az_probe_with_retry 3 3 az network bastion show \
        --only-show-errors \
        --name "$BASTION_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query "provisioningState" \
        --output tsv; then
        err "Failed to query Bastion provisioning state while waiting."
        print_az_failure "$?"
        exit 1
      fi

      BASTION_STATE="$AZ_PROBE_OUTPUT"
      [[ "$BASTION_STATE" == "Succeeded" ]] && break
      if [[ "$BASTION_STATE" == "Failed" ]]; then
        err "Bastion provisioning failed. Check the Azure portal."
        exit 1
      fi
    done
    ok "Bastion is ready"
    ;;
  "")
    err "Bastion '${BASTION_NAME}' not found in resource group '${RESOURCE_GROUP}'"
    exit 1
    ;;
  *)
    err "Bastion is in unexpected state: '${BASTION_STATE}'. Check the Azure portal."
    exit 1
    ;;
esac

# ── Port selection ────────────────────────────────────────────────────────────

SOCKS_PORT=$(find_free_port "$START_PORT")
if [[ "$SOCKS_PORT" -ne "$START_PORT" ]]; then
  warn "Port $START_PORT is in use. Using port $SOCKS_PORT instead."
fi

# ── Print proxy connection details ────────────────────────────────────────────

echo ""
echo -e "  ${BOLD}${GREEN}Preparing SOCKS5 proxy on localhost:${SOCKS_PORT}${RESET}"
echo ""
echo -e "  ${BOLD}export HTTPS_PROXY=socks5://localhost:${SOCKS_PORT}${RESET}"
echo -e "  ${BOLD}export HTTP_PROXY=socks5://localhost:${SOCKS_PORT}${RESET}"
echo ""
echo -e "  Or per-command:  curl --socks5-hostname localhost:${SOCKS_PORT} <url>"
echo ""
echo -e "  ${BOLD}Session started :${RESET} ${LOGIN_AT}"
echo -e "  ${BOLD}Session expires :${RESET} ${EXPIRE_AT}  (Entra ID 12h limit)"
echo -e "  You will be warned 1 hour before expiry and the tunnel will stop at expiry."
echo -e "  The proxy becomes usable only after the Bastion SSH session starts successfully."
echo ""
echo -e "  Connecting via Bastion (auth: AAD). Press ${BOLD}Ctrl+C${RESET} to stop."
echo ""

# ── SSH options passed through to the underlying SSH process ──────────────────
#
# -D  SOCKS5 dynamic port forwarding on the chosen local IPv4 loopback port
# -N  do not execute a remote command (keep connection open for forwarding)
# StrictHostKeyChecking=no   acceptable here: Bastion already provides mutual
#                            auth; the VM has no public surface to MITM
# ServerAliveInterval/Count  keep the tunnel alive through idle periods

SSH_OPTS="-D 127.0.0.1:${SOCKS_PORT} -N \
  -o StrictHostKeyChecking=no \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3"

# ── Session expiry timer ──────────────────────────────────────────────────────────────
#
# Background process: warns 1h before the 12h Entra ID session limit and
# terminates the tunnel if the session expires.

_session_timer() {
  local expire_epoch=$1
  local parent_pid=$2
  local warned=false
  local warn_epoch=$((expire_epoch - 3600))   # 1h before expiry

  while true; do
    sleep 60
    local now
    now=$(date +%s)

    if [[ $now -ge $expire_epoch ]]; then
      echo "" >&2
      err "Azure CLI session has expired (12h limit). Stopping proxy." >&2
      err "Run the script again to re-authenticate." >&2
      kill -TERM "$parent_pid" 2>/dev/null || true
      return
    elif [[ $now -ge $warn_epoch && "$warned" == "false" ]]; then
      warned=true
      echo "" >&2
      warn "Azure CLI session expires in ~60 minutes. Restart the script soon." >&2
    fi
  done
}

log_listener_snapshot() {
  local port=$1
  local snapshot=""

  if [[ "$(detect_os)" == "windows" ]] && command -v netstat &>/dev/null; then
    snapshot=$(netstat -ano 2>/dev/null | tr -d '\r' | grep -E "TCP[[:space:]]+[0-9.:]+:${port}[[:space:]]+[0-9.:]+[[:space:]]+LISTENING" || true)
  elif command -v ss &>/dev/null; then
    snapshot=$(ss -tln 2>/dev/null | grep -E ":${port}[[:space:]]" || true)
  elif command -v netstat &>/dev/null; then
    snapshot=$(netstat -ano 2>/dev/null | tr -d '\r' | grep -E ":${port}[[:space:]]" || true)
  fi

  if [[ -n "$snapshot" ]]; then
    info "Listener snapshot for port ${port}:"
    echo "$snapshot"
  else
    info "No listener snapshot found for port ${port} yet."
  fi
}

log_command_tail() {
  local log_path=$1
  local tail_lines=${2:-40}

  if [[ ! -f "$log_path" ]]; then
    warn "No Bastion command log was captured at ${log_path}"
    return
  fi

  warn "Recent Azure Bastion SSH output from ${log_path}:"
  tail -n "$tail_lines" "$log_path"
}

# ── Cleanup handler ──────────────────────────────────────────────────────────────────────────────

TIMER_PID=""
AZ_PID=""
AZ_EXIT_CODE=""
TUNNEL_READY=false
COMMAND_LOG=""

cleanup() {
  local exit_code=$?
  [[ -n "${TIMER_PID}" ]] && kill "${TIMER_PID}" 2>/dev/null || true
  [[ -n "${AZ_PID}" ]] && kill "${AZ_PID}" 2>/dev/null || true
  echo ""
  if [[ "$TUNNEL_READY" != "true" ]]; then
    err "Bastion SSH exited before the SOCKS5 proxy became ready on localhost:${SOCKS_PORT}."
    err "No listener was created. The Azure CLI Bastion/SSH handoff failed before the tunnel came up."
    [[ -n "${COMMAND_LOG}" ]] && log_command_tail "$COMMAND_LOG"
    [[ -n "$AZ_EXIT_CODE" ]] && warn "Bastion SSH process exit code: ${AZ_EXIT_CODE}."
  elif [[ $exit_code -eq 0 || $exit_code -eq 130 ]]; then
    ok "SOCKS5 proxy stopped."
  else
    warn "SOCKS5 proxy exited with code $exit_code."
  fi

  [[ -n "${COMMAND_LOG}" ]] && rm -f "${COMMAND_LOG}"
}
trap cleanup EXIT

# ── Start SOCKS5 proxy ────────────────────────────────────────────────────────
#
# az network bastion ssh establishes an SSH session through Azure Bastion.
# --ssh-args are forwarded to the underlying SSH client unchanged.
# The process blocks until the connection is closed (Ctrl+C).
# Start the session expiry timer in the background before the tunnel blocks.
info "Starting session expiry timer..."
_session_timer "$EXPIRE_EPOCH" "$$" &
TIMER_PID=$!
info "Session expiry timer started with PID ${TIMER_PID}."
# Git Bash/MSYS rewrites arguments that look like Unix paths when calling
# Windows executables. Azure resource IDs begin with /subscriptions/... and
# must be passed through unchanged.
COMMAND_LOG=$(mktemp "${TMPDIR:-/tmp}/bastion-proxy.XXXXXX.log")
info "Capturing Azure Bastion SSH output to: ${COMMAND_LOG}"
info "Launching Azure Bastion SSH tunnel for VM resource ID: ${VM_ID}"
info "SSH forwarding arguments: ${SSH_OPTS}"
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' az network bastion ssh \
  --name "$BASTION_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --target-resource-id "$VM_ID" \
  --auth-type "AAD" \
  -- $SSH_OPTS \
  > >(tee -a "$COMMAND_LOG") \
  2> >(tee -a "$COMMAND_LOG" >&2) &
AZ_PID=$!
info "Azure Bastion SSH process started with PID ${AZ_PID}. Waiting for SOCKS listener on localhost:${SOCKS_PORT}..."

WAIT_STARTED_AT=$(date +%s)
LAST_WAIT_LOG=0
SNAPSHOT_LOGGED=false

while true; do
  if is_port_in_use "$SOCKS_PORT"; then
    TUNNEL_READY=true
    ok "SOCKS5 proxy ready on localhost:${SOCKS_PORT}"
    launch_proxy_browser "$SOCKS_PORT"
    break
  fi

  if ! kill -0 "$AZ_PID" 2>/dev/null; then
    warn "Azure Bastion SSH process ${AZ_PID} is no longer running before the SOCKS listener was detected."
    break
  fi

  WAIT_ELAPSED=$(( $(date +%s) - WAIT_STARTED_AT ))
  if (( WAIT_ELAPSED >= 5 && WAIT_ELAPSED != LAST_WAIT_LOG && WAIT_ELAPSED % 5 == 0 )); then
    LAST_WAIT_LOG=$WAIT_ELAPSED
    info "Still waiting for SOCKS listener on localhost:${SOCKS_PORT} after ${WAIT_ELAPSED}s (az pid ${AZ_PID} still running)."
    if [[ "$SNAPSHOT_LOGGED" != "true" ]]; then
      log_listener_snapshot "$SOCKS_PORT"
      SNAPSHOT_LOGGED=true
    fi
  fi

  sleep 1
done

if wait "$AZ_PID"; then
  AZ_EXIT_CODE=0
else
  AZ_EXIT_CODE=$?
fi

info "Azure Bastion SSH process ${AZ_PID} exited with code ${AZ_EXIT_CODE}."
exit "$AZ_EXIT_CODE"
