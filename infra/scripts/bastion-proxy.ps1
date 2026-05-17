#!/usr/bin/env pwsh
# =============================================================================
# bastion-proxy.ps1 — SOCKS5 proxy via Azure Bastion
# =============================================================================
#
# Creates a SOCKS5 proxy on your local machine by tunnelling through Azure
# Bastion to the jumpbox VM.  All traffic routed through the proxy is resolved
# and forwarded by the jumpbox, giving access to private PaaS endpoints
# without a VPN.
#
# PREREQUISITES
#   Azure CLI:         https://learn.microsoft.com/cli/azure/install-azure-cli
#   bastion extension: az extension add --name bastion
#   ssh extension:     az extension add --name ssh   (AAD auth only)
#   Standard SKU Azure Bastion with native tunnelling enabled
#   The signing-in Entra user, or a group they belong to, must have
#   a manual "Virtual Machine Administrator Login" assignment on the
#   Linux jumpbox VM (AAD auth)
#
# AUTHENTICATION
#   Uses normal Azure CLI Entra browser login with MFA.
#   Entra login alone is not enough; the authenticated user must also be
#   authorized on the Linux VM through a manual VM login RBAC assignment.
#
# USAGE
#   .\scripts\bastion-proxy.ps1 -ResourceGroup <rg> -BastionName <name> -VmName <vm>
#
# EXAMPLES
#   # Entra ID (AAD) auth:
#   .\scripts\bastion-proxy.ps1 -ResourceGroup eo-dmi-alz-bastion-jumpbox-tools -BastionName eo-dmi-alz-bastion-jumpbox-bastion -VmName eo-dmi-alz-bastion-jumpbox-jumpbox
#
#   # Override the active Azure subscription if needed:
#   .\scripts\bastion-proxy.ps1 -ResourceGroup eo-dmi-alz-bastion-jumpbox-tools -BastionName eo-dmi-alz-bastion-jumpbox-bastion -VmName eo-dmi-alz-bastion-jumpbox-jumpbox -SubscriptionId <subscription-id>
#
#   # Default subscription if omitted:
#   ffc5e617-7f2d-4ddb-8b57-33fc43989a8c
#
# =============================================================================

[CmdletBinding()]
param(
    [Alias('g')]
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Alias('b')]
    [Parameter(Mandatory)]
    [string]$BastionName,

    [Alias('v')]
    [Parameter(Mandatory)]
    [string]$VmName,

    [Alias('s')]
    [string]$SubscriptionId = 'ffc5e617-7f2d-4ddb-8b57-33fc43989a8c',

    [Alias('p')]
    [int]$Port = 8228
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Info { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-Ok { param([string]$Msg) Write-Host "[ OK ]  $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-Err { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }

function Invoke-AzProbe {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Command
    )

    $nativeErrorPreference = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $previousErrorActionPreference = $ErrorActionPreference
    if ($nativeErrorPreference) {
        $previousNativeErrorPreference = $nativeErrorPreference.Value
        $script:PSNativeCommandUseErrorActionPreference = $false
    }
    $script:ErrorActionPreference = 'Continue'

    try {
        $output = & $Command 2>$null
        return [pscustomobject]@{
            Output   = @($output)
            ExitCode = $LASTEXITCODE
        }
    }
    finally {
        $script:ErrorActionPreference = $previousErrorActionPreference
        if ($nativeErrorPreference) {
            $script:PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
        }
    }
}

function Get-AzProbeText {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Command
    )

    $result = Invoke-AzProbe -Command $Command
    $text = ($result.Output | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToString().TrimEnd() }) -join [Environment]::NewLine

    return [pscustomobject]@{
        Output   = $text.Trim()
        ExitCode = $result.ExitCode
    }
}

function Install-AzExtensionIfMissing {
    param(
        [Parameter(Mandatory)]
        [string]$ExtensionName
    )

    $extensionProbe = Get-AzProbeText -Command {
        az extension list --only-show-errors --query "[?name=='$ExtensionName'].name | [0]" --output tsv
    }
    if ($extensionProbe.ExitCode -eq 0 -and $extensionProbe.Output -eq $ExtensionName) {
        return
    }

    Write-Info "Installing Azure CLI '$ExtensionName' extension..."
    az extension add --name $ExtensionName --yes --only-show-errors 2>&1 | Out-Null

    $extensionProbe = Get-AzProbeText -Command {
        az extension list --only-show-errors --query "[?name=='$ExtensionName'].name | [0]" --output tsv
    }
    if ($extensionProbe.ExitCode -ne 0 -or $extensionProbe.Output -ne $ExtensionName) {
        Write-Err "Azure CLI '$ExtensionName' extension could not be installed."
        exit 1
    }
}

function Test-AzLogin {
    $loginProbe = Get-AzProbeText -Command {
        az account list --only-show-errors --query "[?isDefault].id | [0]" --output tsv
    }

    return ($loginProbe.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($loginProbe.Output))
}

function Get-ProxyBrowser {
    $candidates = @(
        @{
            Name  = 'Edge'
            Paths = @(
                (Join-Path $env:LocalAppData 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
            )
        },
        @{
            Name  = 'Chrome'
            Paths = @(
                (Join-Path $env:LocalAppData 'Google\Chrome\Application\chrome.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
                (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')
            )
        }
    )

    foreach ($candidate in $candidates) {
        foreach ($path in $candidate.Paths) {
            if ($path -and (Test-Path $path)) {
                return [pscustomobject]@{
                    Name = $candidate.Name
                    Path = $path
                }
            }
        }
    }

    return $null
}

function Start-ProxyBrowser {
    param([int]$ProxyPort)

    $browser = Get-ProxyBrowser
    if (-not $browser) {
        Write-Warn 'Edge and Chrome were not found. Skipping automatic browser launch.'
        return
    }

    $profileDir = Join-Path $env:TEMP ("bastion-proxy-{0}" -f $browser.Name.ToLowerInvariant())
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null

    $arguments = @(
        '--new-window'
        "--proxy-server=socks5://127.0.0.1:$ProxyPort"
        "--user-data-dir=$profileDir"
        '--no-first-run'
        'about:blank'
    )

    Start-Process -FilePath $browser.Path -ArgumentList $arguments | Out-Null
    Write-Ok ("Opened {0} with SOCKS5 proxy localhost:{1}" -f $browser.Name, $ProxyPort)
}

# ── Port utilities ────────────────────────────────────────────────────────────

function Test-PortInUse {
    param([int]$TestPort)
    $listening = netstat -ano 2>$null | Select-String "TCP\s+[0-9.:]+:${TestPort}\s+[0-9.:]+\s+LISTENING"
    return [bool]$listening
}

function Find-FreePort {
    param([int]$StartPort)
    $limit = $StartPort + 50
    for ($p = $StartPort; $p -le $limit; $p++) {
        if (-not (Test-PortInUse $p)) { return $p }
    }
    Write-Err "No free port found in range $StartPort–$limit"
    exit 1
}

function Write-ListenerSnapshot {
    param([int]$SnapshotPort)

    $snapshot = netstat -ano 2>$null | Select-String "TCP\s+[0-9.:]+:${SnapshotPort}\s+[0-9.:]+\s+LISTENING"
    if ($snapshot) {
        Write-Info "Listener snapshot for port ${SnapshotPort}:"
        $snapshot | ForEach-Object { Write-Host $_.ToString() }
    }
    else {
        Write-Info "No listener snapshot found for port $SnapshotPort yet."
    }
}

# ── Prerequisite checks ───────────────────────────────────────────────────────

Write-Info 'Checking prerequisites...'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Err 'Azure CLI (az) is not installed.'
    Write-Err 'Install: https://learn.microsoft.com/cli/azure/install-azure-cli'
    exit 1
}

if (-not $env:AZURE_EXTENSION_DIR) {
    $env:AZURE_EXTENSION_DIR = Join-Path $HOME '.azure\cliextensions-bastion-proxy'
    Write-Info "Using dedicated Azure CLI extension cache: $env:AZURE_EXTENSION_DIR"
}
New-Item -ItemType Directory -Force -Path $env:AZURE_EXTENSION_DIR | Out-Null

Install-AzExtensionIfMissing -ExtensionName 'bastion'
Install-AzExtensionIfMissing -ExtensionName 'ssh'

Write-Ok 'Prerequisites satisfied'

# ── Authentication ────────────────────────────────────────────────────────────

Write-Info 'Checking Azure CLI login status...'
if (-not (Test-AzLogin)) {
    Write-Host ''
    Write-Info 'Not logged in. Starting Entra browser authentication...'
    Write-Host ''
    Write-Warn 'Complete the MFA prompt in the browser window opened by Azure CLI.'
    Write-Host ''
    az login
    if (-not (Test-AzLogin)) {
        Write-Err 'Azure CLI login did not complete successfully.'
        exit 1
    }
}
else {
    Write-Warn 'Already logged in. Azure CLI sessions expire 12h after az login.'
    Write-Warn 'Re-run this script if you encounter authentication errors.'
}

$loginEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$expireEpoch = $loginEpoch + 43200
$loginAt = Get-Date -Format 'HH:mm zzz'
$expireAt = (Get-Date).AddHours(12).ToString('HH:mm zzz')

Write-Ok 'Authenticated to Azure CLI'

# ── Subscription ──────────────────────────────────────────────────────────────

if ($SubscriptionId) {
    Write-Info "Switching to subscription $SubscriptionId..."
    az account set --subscription $SubscriptionId 2>&1 | Out-Null
}
else {
    $SubscriptionId = az account show --query id --output tsv
    Write-Info 'Using current Azure subscription...'
}
$subName = az account show --query name --output tsv
Write-Ok "Using: $subName ($SubscriptionId)"

# ── Resolve VM resource ID ────────────────────────────────────────────────────

Write-Info "Resolving VM '$VmName' in resource group '$ResourceGroup'..."
$vmLookup = Get-AzProbeText -Command { az vm show --name $VmName --resource-group $ResourceGroup --query id --output tsv }
$vmId = $vmLookup.Output
if ($vmLookup.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($vmId)) {
    Write-Err "VM '$VmName' not found in resource group '$ResourceGroup'"
    exit 1
}
Write-Ok 'VM found'

# ── VM running check ──────────────────────────────────────────────────────────

$vmStateLookup = Get-AzProbeText -Command {
    az vm get-instance-view `
        --name $VmName `
        --resource-group $ResourceGroup `
        --query "instanceView.statuses[?contains(code,'PowerState')].displayStatus | [0]" `
        --output tsv
}
$vmState = $vmStateLookup.Output
if ($vmStateLookup.ExitCode -ne 0) {
    Write-Err "Failed to query VM power state for '$VmName'"
    exit 1
}

if ($vmState -ne 'VM running') {
    if ([string]::IsNullOrWhiteSpace($vmState)) {
        $vmStateDisplay = 'unknown'
    }
    else {
        $vmStateDisplay = $vmState
    }
    Write-Warn "VM is not running (current state: $vmStateDisplay)"
    $answer = Read-Host '  Start the VM now? [y/N]'
    if ($answer.ToLower() -eq 'y') {
        Write-Info 'Starting VM...'
        az vm start --name $VmName --resource-group $ResourceGroup 2>&1 | Out-Null
        Write-Info 'Waiting for VM to reach running state...'
        az vm wait --name $VmName --resource-group $ResourceGroup `
            --custom "instanceView.statuses[?code=='PowerState/running']" 2>&1 | Out-Null
        Write-Ok 'VM is running'
    }
    else {
        Write-Err 'VM must be running to create a proxy tunnel. Exiting.'
        exit 1
    }
}

# ── Bastion health check ──────────────────────────────────────────────────────

Write-Info "Checking Bastion host '$BastionName'..."
$bastionLookup = Get-AzProbeText -Command {
    az network bastion show `
        --name $BastionName `
        --resource-group $ResourceGroup `
        --query provisioningState `
        --output tsv
}
$bastionState = $bastionLookup.Output

if ($bastionLookup.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($bastionState)) {
    Write-Err "Bastion '$BastionName' not found in resource group '$ResourceGroup'"
    exit 1
}

switch ($bastionState) {
    'Succeeded' {
        Write-Ok 'Bastion is ready'
    }
    { $_ -in @('Updating', 'Creating') } {
        Write-Info "Bastion is provisioning (state: $bastionState). Waiting..."
        while ($true) {
            Start-Sleep -Seconds 15
            $bastionLookup = Get-AzProbeText -Command {
                az network bastion show --name $BastionName --resource-group $ResourceGroup --query provisioningState --output tsv
            }
            $bastionState = $bastionLookup.Output
            if ($bastionLookup.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($bastionState)) {
                Write-Err 'Failed to query Bastion provisioning state while waiting.'
                exit 1
            }
            if ($bastionState -eq 'Succeeded') { Write-Ok 'Bastion is ready'; break }
            if ($bastionState -eq 'Failed') {
                Write-Err 'Bastion provisioning failed. Check the Azure portal.'
                exit 1
            }
        }
    }
    default {
        Write-Err "Bastion is in unexpected state: '$bastionState'. Check the Azure portal."
        exit 1
    }
}

# ── Port selection ────────────────────────────────────────────────────────────

$socksPort = Find-FreePort $Port
if ($socksPort -ne $Port) {
    Write-Warn "Port $Port is in use. Using port $socksPort instead."
}

# ── Print proxy connection details ────────────────────────────────────────────

Write-Host ''
Write-Host "  Preparing SOCKS5 proxy on localhost:$socksPort" -ForegroundColor Green -BackgroundColor Black
Write-Host ''
Write-Host "  `$env:HTTPS_PROXY = 'socks5://localhost:$socksPort'"
Write-Host "  `$env:HTTP_PROXY  = 'socks5://localhost:$socksPort'"
Write-Host ''
Write-Host "  Or per-command:  curl --socks5-hostname localhost:$socksPort <url>"
Write-Host ''
Write-Host "  Session started : $loginAt"
Write-Host "  Session expires : $expireAt  (Entra ID 12h limit)"
Write-Host '  You will be warned 1 hour before expiry; the tunnel stops at expiry.'
Write-Host '  The proxy becomes usable only after the Bastion SSH session starts successfully.'
Write-Host ''
Write-Host '  Connecting via Bastion (auth: AAD). Press Ctrl+C to stop.'
Write-Host ''

# ── Build az argument array ───────────────────────────────────────────────────
#
# Arguments after '--' are passed directly to the underlying SSH client:
#   -D  SOCKS5 dynamic port forwarding on the chosen local IPv4 loopback port
#   -N  do not execute a remote command (keep connection open for forwarding)
#   -q  quiet mode (suppress banners and warnings)
#   StrictHostKeyChecking=no   Bastion already provides mutual auth
#   ServerAliveInterval/Count  keep the tunnel alive through idle periods

$sshOptsStr = "-D 127.0.0.1:$socksPort -N -q -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3"

$azCmdLine = "network bastion ssh --name `"$BastionName`" --resource-group `"$ResourceGroup`" --target-resource-id `"$vmId`" --auth-type AAD -- $sshOptsStr"

# ── Write temp batch file to avoid cmd /c quoting issues ─────────────────────
#
# Writing a .bat avoids the cmd.exe quoting edge-cases that arise when az.cmd
# (which lives in a path with spaces) is passed as an argument to /c.

$tempBat = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.bat')
"@az $azCmdLine" | Set-Content -Path $tempBat -Encoding ASCII

Write-Info "Prepared Azure Bastion SSH command file: $tempBat"
Write-Info "Launching Azure Bastion SSH tunnel for VM resource ID: $vmId"
Write-Info "SSH forwarding arguments: $sshOptsStr"

# ── Start az process (inherit console so output flows through) ────────────────
#
# Start-Process with -NoNewWindow and no stream redirection means the child
# inherits our stdin/stdout/stderr — az output appears in this terminal.
# -PassThru gives us the process object for the timer kill.

$proc = Start-Process -FilePath 'cmd.exe' `
    -ArgumentList "/c `"$tempBat`"" `
    -NoNewWindow -PassThru

Write-Info "Azure Bastion SSH process started with PID $($proc.Id). Waiting for SOCKS listener on localhost:$socksPort..."

$tunnelReady = $false
$waitStartedAt = Get-Date
$lastWaitLogAt = -1
$snapshotLogged = $false
while ($true) {
    if (Test-PortInUse $socksPort) {
        $tunnelReady = $true
        Write-Ok "SOCKS5 proxy ready on localhost:$socksPort"
        Start-ProxyBrowser $socksPort
        break
    }

    if ($proc.HasExited) {
        Write-Warn "Azure Bastion SSH process $($proc.Id) exited before the SOCKS listener was detected."
        break
    }

    $waitElapsed = [int]((Get-Date) - $waitStartedAt).TotalSeconds
    if ($waitElapsed -ge 5 -and $waitElapsed -ne $lastWaitLogAt -and $waitElapsed % 5 -eq 0) {
        $lastWaitLogAt = $waitElapsed
        Write-Info "Still waiting for SOCKS listener on localhost:$socksPort after ${waitElapsed}s (az pid $($proc.Id) still running)."
        if (-not $snapshotLogged) {
            Write-ListenerSnapshot -SnapshotPort $socksPort
            $snapshotLogged = $true
        }
    }

    Start-Sleep -Milliseconds 250
}

# ── Session expiry timer (background runspace) ────────────────────────────────
#
# Runs in a separate runspace so it doesn't block WaitForExit below.
# On expiry it kills the entire process tree via taskkill /T.

$runspace = $null
$rsPs = $null
$timerAsyncResult = $null
if ($tunnelReady) {
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $rsPs = [powershell]::Create()
    $rsPs.Runspace = $runspace
    $null = $rsPs.AddScript({
            param([long]$ExpireEpoch, [int]$ProcId)
            $warned = $false
            $warnEpoch = $ExpireEpoch - 3600
            while ($true) {
                Start-Sleep -Seconds 60
                $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                if ($now -ge $ExpireEpoch) {
                    [Console]::Error.WriteLine('')
                    [Console]::Error.WriteLine('[ERROR] Azure CLI session has expired (12h limit). Stopping proxy.')
                    [Console]::Error.WriteLine('[ERROR] Re-run the script to re-authenticate.')
                    $null = & taskkill /F /T /PID $ProcId 2>$null
                    break
                }
                elseif ($now -ge $warnEpoch -and -not $warned) {
                    $warned = $true
                    [Console]::Error.WriteLine('')
                    [Console]::Error.WriteLine('[WARN]  Azure CLI session expires in ~60 minutes. Restart the script soon.')
                }
            }
        }).AddParameters(@{ ExpireEpoch = $expireEpoch; ProcId = $proc.Id })
    $timerAsyncResult = $rsPs.BeginInvoke()
    if (-not $timerAsyncResult) { throw 'Failed to start session expiry timer.' }
}

# ── Wait for proxy process to exit ────────────────────────────────────────────

try {
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    Write-Info "Azure Bastion SSH process $($proc.Id) exited with code $exitCode."
}
finally {
    # Stop the timer runspace
    if ($timerAsyncResult) {
        try { $timerAsyncResult.AsyncWaitHandle.Close() } catch {}
    }
    if ($rsPs) {
        try { $rsPs.Stop() } catch {}
        try { $rsPs.Dispose() } catch {}
    }
    if ($runspace) {
        try { $runspace.Dispose() } catch {}
    }

    # Ensure process tree is dead (idempotent if already exited)
    if (-not $proc.HasExited) {
        $null = & taskkill /F /T /PID $proc.Id 2>$null
    }
    $proc.Dispose()

    Remove-Item $tempBat -Force -ErrorAction SilentlyContinue

    Write-Host ''
    if (-not $tunnelReady) {
        Write-Err "Bastion SSH exited before the SOCKS5 proxy became ready on localhost:$socksPort."
        Write-Err 'No listener was created. The Azure CLI Bastion/SSH handoff failed before the tunnel came up.'
        if ($null -ne $exitCode) {
            Write-Warn "Bastion SSH process exit code: $exitCode"
        }
    }
    elseif ($null -eq $exitCode -or $exitCode -eq 0 -or $exitCode -eq 130) {
        Write-Ok 'SOCKS5 proxy stopped.'
    }
    else {
        Write-Warn "SOCKS5 proxy exited with code $exitCode."
    }
}
