# Azure Bastion and Jumpbox VM

This module deploys a minimal Azure Linux VM used as an Azure Bastion native-client tunnel endpoint for SOCKS5 access to private Azure resources.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Internet                                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Azure Portal (HTTPS)                         │
│                    https://portal.azure.com                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Azure Bastion (Standard SKU)                 │
│                    AzureBastionSubnet /26                       │
│                    Public IP: Standard SKU                      │
│                    Native client tunneling enabled              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ SSH (Port 22)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Jumpbox VM (Dedicated B-series)              │
│                    Ubuntu 24.04 LTS                             │
│                    Minimal tunnel endpoint                      │
│                    Entra ID SSH Access via Bastion              │
│                    jumpbox-subnet /28                           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ Private Endpoints
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              Azure PaaS Services (Private Access)               │
│    • Azure OpenAI    • Cosmos DB    • Azure AI Search           │
│    • Document Intelligence    • Key Vault                       │
└─────────────────────────────────────────────────────────────────┘
```

## Features

- **Dedicated B-series VM**: Cost-effective burstable compute with consistent availability (no evictions)
- **Ubuntu 24.04 LTS**: Latest LTS release (Noble Numbat) with long-term support until 2034
- **Minimal VM**: No desktop environment or DevOps tool installation; the VM exists only as a tunnel endpoint
- **Azure Bastion**: Secure SSH access without public IP on VM (Standard SKU with native CLI tunneling)
- **Entra ID SSH Login**: Microsoft Entra ID (AAD) authentication via `AADSSHLoginForLinux` VM extension; developer access uses Entra ID rather than SSH key sign-in, but the signing-in user or one of their groups must also have a manual `Virtual Machine Administrator Login` assignment on the Linux jumpbox VM
- **Managed Identity**: Access Azure services without storing credentials
- **Random Admin Username**: 12-char alphanumeric username for added security
- **Auto-Shutdown**: VM automatically shuts down at 7 PM PST daily
- **Auto-Start**: VM automatically starts at 8 AM PST Monday-Friday using Azure Automation

## VM Schedule

The Jumpbox VM has automatic scheduling to minimize costs:

| Action | Time | Days | Mechanism |
|--------|------|------|-----------|
| **Auto-Shutdown** | 7:00 PM PST | Daily (including weekends) | Azure DevTest Labs Schedule |
| **Auto-Start** | 8:00 AM PST | Monday-Friday only | Azure Automation Runbook (Python3) |

### Schedule Details

- **Weekdays (Mon-Fri)**: VM runs from 8 AM to 7 PM PST
- **Weekends (Sat-Sun)**: VM stays off unless manually started
- **Time Zone**: Pacific Standard Time (PST/PDT)

### Manual Override

If you need the VM outside scheduled hours:

```bash
# Start VM manually via Azure CLI
az vm start --resource-group <rg-name> --name <vm-name>

# Stop VM manually
az vm deallocate --resource-group <rg-name> --name <vm-name>
```

Or via Azure Portal:
1. Navigate to **Virtual Machines** → Select your Jumpbox
2. Click **Start** or **Stop** button

## Connecting to the Jumpbox VM

### Via Azure CLI with Entra ID (Recommended)

When Entra ID login is enabled (`enable_entra_login = true`), you can SSH using your Entra identity without any SSH keys, as long as the signing-in Entra user or one of their groups has a manual `Virtual Machine Administrator Login` assignment on the Linux jumpbox VM:

```bash
# Login to Azure CLI
az login

# SSH via Bastion using Entra ID authentication
az network bastion ssh \
  --name <bastion-name> \
  --resource-group <rg-name> \
  --target-resource-id <vm-resource-id> \
  --auth-type AAD

# Or tunnel a port for local SSH client access
az network bastion tunnel \
  --name <bastion-name> \
  --resource-group <rg-name> \
  --target-resource-id <vm-resource-id> \
  --resource-port 22 \
  --port 2222
# Then in another terminal: ssh -p 2222 localhost
```

> **Prerequisites**: Requires Azure CLI with the `bastion` extension (`az extension add --name bastion`). The specific Entra user you sign in with, or a group they belong to, must be granted `Virtual Machine Administrator Login` manually on the Linux jumpbox VM.

If this RBAC assignment is missing, the Bastion connection can reach the VM but Entra SSH authentication will fail, typically with `Permission denied (publickey)`.

For the `b9cee3` tools environment, make this a manual VM step for:

- `DO_PuC_Azure_Live_b9cee3_Owners`
- `DO_PuC_Azure_Live_b9cee3_Contributors`

Terraform creates a bootstrap SSH key internally because Azure requires an `admin_ssh_key` for Linux VM creation when password authentication is disabled. There is no local key file, but the private key is retained in Terraform state and exposed as a sensitive output for break-glass recovery. Interactive access is still expected to use Entra ID through Azure Bastion.

## SOCKS5 Proxy for Private PaaS Access

The `bastion-proxy.sh` script creates a SOCKS5 proxy on your local machine by
tunnelling through Azure Bastion to the jumpbox VM. Once running, any tool that
supports SOCKS5 can reach private PaaS endpoints the jumpbox can see — no VPN
required, and **a single proxy port handles all endpoints simultaneously**.

### How It Works

```
Your machine  ──────────────────────────────────────────────────────────────▶
  │                                                                         │
  │  SOCKS5 (localhost:8228)                                                │
  ▼                                                                         │
az network bastion ssh ──▶ Azure Bastion ──▶ Jumpbox VM ──▶ Private endpoints
                            (authenticated)   (DNS resolver)
                                                              • CosmosDB
                                                              • PostgreSQL
                                                              • Redis
                                                              • Azure OpenAI
                                                              • AI Search
                                                              • Key Vault
```

The jumpbox resolves hostnames and forwards TCP traffic on your behalf. Because
SOCKS5 proxies DNS through the jumpbox, every private endpoint the jumpbox can
reach is instantly accessible through the one proxy port — no per-service
tunnel configuration is needed.

### Running the Proxy

> **Important: use Entra browser login with MFA**
>
> Sign in with `az login` and complete the MFA prompt in the browser window
> opened by Azure CLI. The Entra user you sign in with, or one of their groups, must also have a manual `Virtual Machine Administrator Login` assignment on the Linux jumpbox VM.

```bash
# Prerequisites (one-time setup)
az extension add --name bastion
az extension add --name ssh   # AAD auth only

# Entra ID (AAD) auth — recommended
# Run from initial-setup/infra/
./scripts/bastion-proxy.sh \
  --resource-group <rg-name> \
  --bastion-name <app_name>-bastion \
  --vm-name <app_name>-jumpbox

```

The script will:
1. Run browser-based `az login` if not already authenticated
2. Use the current Azure subscription, or switch if you pass one explicitly
3. Find an available SOCKS5 port starting at 8228 (tries next ports automatically if 8228 is in use)
4. Start the VM if it is stopped (prompts for confirmation)
5. Verify the Bastion host is in a healthy provisioning state (waits if still provisioning)
6. Open the Bastion tunnel and print the proxy address with session expiry time
7. Block until `Ctrl+C` — warns 1 hour before the 12h Entra ID session limit and stops automatically at expiry

If the SOCKS proxy never comes up and the underlying SSH call reports an Entra authentication failure, verify that the actual user account you authenticated with has a manual `Virtual Machine Administrator Login` assignment on the Linux jumpbox VM.

### Configuring Tools to Use the Proxy

Set environment variables to route all tools through the proxy:

```bash
export HTTPS_PROXY=socks5://localhost:8228
export HTTP_PROXY=socks5://localhost:8228
```

Or use per-command flags. All examples below use the **same proxy port** regardless
of which PaaS endpoint you are targeting.

#### Azure CLI

```bash
HTTPS_PROXY=socks5://localhost:8228 az cosmosdb list --resource-group <rg>
HTTPS_PROXY=socks5://localhost:8228 az keyvault secret list --vault-name <kv>
```

#### curl

```bash
# --socks5-hostname ensures the hostname is resolved by the jumpbox (not locally)
curl --socks5-hostname localhost:8228 https://<account>.documents.azure.com/
curl --socks5-hostname localhost:8228 https://<account>.openai.azure.com/
```

#### PostgreSQL (psql)

```bash
# Via proxychains (Linux/macOS)
proxychains psql "host=<server>.postgres.database.azure.com port=5432 \
  dbname=<db> user=<user> sslmode=require"

# Or set PGPROXY via ~/.proxychains/proxychains.conf
```

#### Redis

```bash
proxychains redis-cli -h <account>.redis.cache.windows.net -p 6380 --tls
```

#### MongoDB / CosmosDB (Mongo API)

```bash
proxychains mongosh "mongodb://<account>.mongo.cosmos.azure.com:10255/..." \
  --tls --tlsAllowInvalidCertificates
```

#### Python / Node.js (environment variable approach)

```python
import os, httpx

# Set before making any requests
os.environ["HTTPS_PROXY"] = "socks5://localhost:8228"

client = httpx.Client()
resp = client.get("https://<account>.openai.azure.com/")
```

### Multiple Connections on One Port

SOCKS5 is a full proxy protocol — a single listener handles unlimited concurrent
connections to different hosts and ports. You do **not** need separate proxy
instances for each PaaS service. All of the following can run simultaneously
through `localhost:8228`:

| Target | Example host |
|--------|-------------|
| Azure OpenAI | `<account>.openai.azure.com` |
| CosmosDB | `<account>.documents.azure.com` |
| PostgreSQL Flexible Server | `<server>.postgres.database.azure.com` |
| Redis Cache | `<account>.redis.cache.windows.net` |
| Azure AI Search | `<account>.search.windows.net` |
| Key Vault | `<vault>.vault.azure.net` |
| APIM private endpoint | `<apim>.azure-api.net` |

### Using Different Ports for Multiple Sessions

If you need two simultaneous proxy sessions (e.g., different subscriptions), pass
`--port` to start the second instance on a different port:

```bash
# Session 1 (default port 8228)
./scripts/bastion-proxy.sh -g <rg> -b <bastion> -v <vm>

# Session 2 in a new terminal (auto-selects next free port after 8300)
./scripts/bastion-proxy.sh -g <rg> -b <bastion> -v <vm> --port 8300
```

## VM Specifications

| Spec | Value |
|------|-------|
| **VM Size** | Standard_B2als_v2 |
| **vCPUs** | 2 |
| **Memory** | 4 GB |
| **Type** | Burstable (B-series) |
| **Priority** | Regular (dedicated, no evictions) |
| **OS Disk** | 64 GB Standard LRS |
| **Estimated Cost** | ~$30-40/month (with auto-shutdown schedule) |

> **Note**: B-series VMs are burstable, meaning they accumulate CPU credits when idle and can burst above baseline when needed. This is ideal for jumpbox workloads with variable usage.

## Auto-Start Implementation

The auto-start feature uses Azure Automation with a Python3 runbook:

- **Automation Account**: System-assigned managed identity with VM Contributor role scoped to the jumpbox VM
- **Runbook**: Python3 script using Azure REST API and the Automation Account managed identity
- **Schedule**: Weekday mornings at 8 AM PST (Monday-Friday)

This does not add SSH keys or alternative VM login methods. It only grants the Automation Account permission to start the VM.

Optional Bastion cost automation can use the same Automation Account when `enable_bastion_automation = true`:

- **Create Runbook**: `Create-BastionHost` recreates the Bastion host and its public IP
- **Delete Runbook**: `Delete-BastionHost` deletes the Bastion host and its public IP
- **Schedules**: Weekday 8 AM Pacific create, daily 7 PM Pacific delete
- **Manual Recovery**: You can start `Create-BastionHost` manually from Azure Automation to bring Bastion back on demand

Because Bastion delete and recreate happens outside Terraform, an off-hours `terraform plan` will show Bastion as absent and ready to recreate. Once the runbook recreates Bastion with the same names, Terraform returns to the expected state.

## Subnet Allocation

| Subnet | CIDR | Purpose |
|--------|------|---------|
| jumpbox-subnet | x.x.x.144/28 | Jumpbox VM (11 usable IPs) |
| AzureBastionSubnet | x.x.x.192/26 | Azure Bastion (59 usable IPs) |

## Security

- **No Public IP**: The Jumpbox VM has no public IP address
- **Random Admin Username**: 12-character alphanumeric username generated at deployment (security by obscurity)
- **Entra ID SSH Authentication**: Password authentication disabled; Terraform uses an internal bootstrap SSH key only to satisfy Linux VM creation, while interactive access uses Entra ID RBAC
- **Entra ID RBAC**: `Virtual Machine Administrator Login` must be associated manually on the Linux jumpbox VM for authorized users or groups, and the actual signing-in user must be covered by that assignment
- **NSG Rules**: Only SSH (22) from Bastion subnet is allowed inbound
- **Private Subnet**: Default outbound access is disabled
- **Managed Identity**: VM can access Azure services without credentials

## Troubleshooting

### Bastion Connection Issues

1. Ensure NSG rules allow traffic between Bastion and VM subnets
2. Check that the VM is in "Running" state
3. Verify the signing-in Entra user, or one of their groups, has a manual `Virtual Machine Administrator Login` assignment on the Linux jumpbox VM
4. Verify the username is correct

### VM Not Starting

1. Check VM state in Azure Portal
2. Click "Start" to start the VM
3. Check Azure Service Health for any regional outages
4. Verify the Automation Account runbook executed successfully for scheduled auto-start issues

---

## Azure Bastion Cost Optimization

Azure Bastion Standard SKU runs a minimum of 2 scale units (instances), so the minimum hourly cost is always 2× the per-instance rate (~$0.397/hour × 2 = ~$0.794/hour in Canada Central). This cost applies even when idle. Here are strategies to reduce costs:

### Option 1: Delete and Recreate Bastion (Recommended)

**Delete Bastion when not needed:**

```bash
# Delete Bastion (keeps the subnet and NSG)
az network bastion delete \
  --name <bastion-name> \
  --resource-group <rg-name>

# Delete the Public IP (saves ~$3/month)
az network public-ip delete \
  --name <bastion-pip-name> \
  --resource-group <rg-name>
```

**Recreate when needed:**

```bash
# Create Public IP
az network public-ip create \
  --name <bastion-pip-name> \
  --resource-group <rg-name> \
  --location canadacentral \
  --sku Standard \
  --allocation-method Static

# Create Bastion (Standard SKU for CLI tunneling support)
az network bastion create \
  --name <bastion-name> \
  --resource-group <rg-name> \
  --location canadacentral \
  --vnet-name <vnet-name> \
  --public-ip-address <bastion-pip-name> \
  --sku Standard \
  --enable-tunneling true
```

### Option 2: Use Terraform Workspace Targeting

```bash
# Destroy only Bastion resources
cd infra
terraform destroy -target=module.bastion

# Recreate when needed
terraform apply -target=module.bastion
```

### Option 3: Automated Schedule with GitHub Actions

Create a scheduled workflow to delete Bastion at end of day:

```yaml
# .github/workflows/bastion-scheduler.yml
name: Bastion Cost Scheduler

on:
  schedule:
    # Delete at 7 PM PST (3 AM UTC next day)
    - cron: '0 3 * * *'
  workflow_dispatch:
    inputs:
      action:
        description: 'Action to perform'
        required: true
        default: 'delete'
        type: choice
        options:
          - delete
          - create

jobs:
  manage-bastion:
    runs-on: ubuntu-latest
    steps:
      - name: Azure Login
        uses: azure/login@v1
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}
      
      - name: Delete Bastion
        if: github.event.inputs.action == 'delete' || github.event_name == 'schedule'
        run: |
          az network bastion delete --name ${{ vars.BASTION_NAME }} --resource-group ${{ vars.RESOURCE_GROUP }} --yes || true
          az network public-ip delete --name ${{ vars.BASTION_PIP_NAME }} --resource-group ${{ vars.RESOURCE_GROUP }} || true
```

### Option 4: Use Bastion Developer SKU (Free)

If you only need basic access, consider using **Bastion Developer SKU**:
- **Cost**: Free (no hourly charges)
- **Limitation**: One VM connection at a time
- **No dedicated subnet required**

⚠️ **Note**: Developer SKU is not deployed via this module. It must be configured per-VM in the portal.

### Cost Comparison

| Resource | Hourly Cost | Monthly Cost (24/7) | Monthly (8AM-7PM M-F) |
|----------|-------------|---------------------|----------------------|
| Bastion Basic | ~$0.19 | ~$140 | ~$45 |
| Bastion Standard | ~$0.35 | ~$260 | ~$80 |
| Public IP (Standard) | ~$0.004 | ~$3 | ~$3 |
| **Total Basic** | - | ~$143 | ~$48 |

**Delete/Recreate Strategy**: If you only use Bastion 2 hours/day for testing, you'd pay ~$12/month instead of $143/month.

### When to Keep Bastion Running

- Multiple team members need VM access throughout the day
- You're actively debugging production issues
- You need immediate access without 5-minute deployment wait

### When to Delete Bastion

- Weekend/holiday periods
- After-hours (if using scheduled deletion)
- Project is in maintenance mode with infrequent access needs
