# Harness.io + Azure AKS — POC Implementation Guide
### Automating Cloud Deployments from Scratch

---

## What This Project Does

This POC deploys a Node.js web application to Azure AKS
using Harness.io as the automation platform.

**End-to-end flow:**

```
Your Terminal
    │
    │  ./scripts/setup_azure.sh  (run once)
    ▼
Azure: Resource Group → ACR → AKS → Service Principal
    │
    │  git push origin main
    ▼
GitHub: harness-azure-poc (stores all manifests)
    │
    │  Harness detects push via github_connector
    ▼
Harness CD Pipeline
    │  ├─ Fetches k8s/deployment.yaml + k8s/service.yaml from GitHub
    │  ├─ Sends task to helm-delegate inside AKS
    │  └─ Delegate runs kubectl apply → pods update
    ▼
AKS: harness-poc namespace
    │  ├─ Pod: harness-poc-app  STATUS: Running  READY: 1/1
    │  └─ Service: LoadBalancer → public IP
    ▼
Browser: http://<EXTERNAL-IP>/   →   Deployment dashboard page
```

---

## Repository Structure

```
harness-poc/
├── app/
│   ├── server.js          Node.js Express server (dashboard + /health)
│   └── package.json       npm dependencies
├── k8s/
│   ├── deployment.yaml    Kubernetes Deployment (1 replica, rolling update)
│   └── service.yaml       Kubernetes Service (Azure LoadBalancer, port 80)
├── .harness/
│   └── pipeline.yaml      Harness Pipeline-as-Code (paste into UI)
├── scripts/
│   └── setup_azure.sh     One-time Azure resource creation script
├── Dockerfile             Multi-stage Docker build for the Node.js app
├── .dockerignore          Excludes node_modules from Docker build context
├── .gitignore             Excludes credentials from GitHub
└── README.md              This guide
```

---

## Phase 0: Install Tools (Mac)

Open **Terminal** (Applications → Utilities → Terminal) and run each command:

```bash
# Install Homebrew (Mac package manager) — skip if already installed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install Azure CLI
brew install azure-cli

# Verify
az --version

# Install kubectl (Kubernetes CLI)
brew install kubectl

# Verify
kubectl version --client

# Install Helm (Kubernetes package manager — needed for the Delegate)
brew install helm

# Verify
helm version

# Install Git
brew install git

# Verify
git --version

# Install Node.js (to test the app locally if needed)
brew install node@20
```

---

## Phase 1: Set Up GitHub Repository

### Step 1.1 — Create repository on GitHub

1. Go to [github.com](https://github.com) and log in with `bhargavaraam29cloud-web`
2. Click **+** (top right) → **New repository**
3. Repository name: `harness-azure-poc`
4. Visibility: **Public**
5. Check **Add a README file**
6. Click **Create repository**

### Step 1.2 — Clone and add project files

```bash
# Clone the new repo to your Mac
git clone https://github.com/bhargavaraam29cloud-web/harness-azure-poc.git
cd harness-azure-poc

# Copy all files from this project into the cloned folder
# (replace SOURCE_PATH with wherever you stored harness-poc/)
cp -r /path/to/harness-poc/* .
cp -r /path/to/harness-poc/.harness .
cp /path/to/harness-poc/.gitignore .
cp /path/to/harness-poc/.dockerignore .
```

### Step 1.3 — Create a GitHub Personal Access Token (PAT)

Harness needs a token to read your repository.

1. GitHub → Settings (your profile, top right) → **Developer settings**
2. **Personal access tokens** → **Tokens (classic)** → **Generate new token**
3. Note: `harness-poc-token`
4. Expiration: 90 days
5. Scopes: check **repo** (all repo permissions)
6. Click **Generate token**
7. **Copy the token now** — you cannot see it again

### Step 1.4 — Push project files

```bash
cd harness-azure-poc

# Stage everything
git add .

# First commit — describes what you built manually
git commit -m "Add Node.js app, Kubernetes manifests, Harness pipeline config"

# Push to GitHub
git push origin main
```

Verify: go to `github.com/bhargavaraam29cloud-web/harness-azure-poc`
You should see all files listed.

---

## Phase 2: Provision Azure Resources

### Step 2.1 — Log in to Azure CLI

```bash
az login
# A browser window opens. Sign in with bhargavaraam29.cloud@gmail.com
# After login, terminal shows your subscriptions.

# Set the correct subscription (Azure subscription 1)
az account set --subscription "8e4b37d6-4aa9-408d-b5ee-f5d2ef51d314"

# Verify
az account show --output table
```

### Step 2.2 — Run the setup script

```bash
cd harness-azure-poc

# Make executable
chmod +x scripts/setup_azure.sh

# Run (takes ~12 minutes — AKS provisioning is slow)
./scripts/setup_azure.sh
```

**What you will see printed at the end:**

```
================================================================
  CREDENTIALS FOR HARNESS CONNECTOR SETUP
================================================================
  Subscription ID : 8e4b37d6-4aa9-408d-b5ee-f5d2ef51d314
  Tenant ID       : 73075061-0c0e-4518-bb0f-9a70320a3354
  Client ID       : 34d460ab-83af-40ea-bad2-b7f3fd6d5afa
  Client Secret   : <generated-secret>   ← save this
  ACR Server      : harnesspoc7058.azurecr.io
================================================================
```

Save the **Client Secret** value — you need it in Phase 3.

### Step 2.3 — Verify everything was created

```bash
# See your 2 nodes (they should say Ready)
kubectl get nodes

# See both namespaces
kubectl get namespaces | grep harness
# Expected output:
# harness-poc             Active   ...
# harness-delegate-ng     Active   ...
```

---

## Phase 3: Configure Harness.io

Open [app.harness.io](https://app.harness.io) and log in.

### Step 3.1 — Create Encrypted Secrets

**What:** Harness stores sensitive values in an encrypted vault.
You reference them by name — the raw value never appears in logs.

Navigate: **Project Settings** (bottom left ⚙️) → **Secrets** → **+ New Secret**

**Secret 1:**

| Field | Value |
|---|---|
| Type | Secret Text |
| Name | `azure_client_secret` |
| Value | The Client Secret from the setup script output |

Click **Save**.

**Secret 2:**

| Field | Value |
|---|---|
| Type | Secret Text |
| Name | `github_pat` |
| Value | Your GitHub PAT from Step 1.3 |

Click **Save**.

Both secrets now appear with a lock icon. Harness encrypts them at rest immediately.

---

### Step 3.2 — Create 4 Connectors

**What:** Connectors are authenticated channels between Harness and external systems.
Once created, pipelines reference them by name — no credentials in pipeline code.

Navigate: **Project Settings** → **Connectors** → **+ New Connector**

---

#### Connector 1 — GitHub (`github_connector`)

| Field | Value |
|---|---|
| Type | GitHub |
| Name | `github_connector` |
| URL Type | Repository |
| Repository URL | `https://github.com/bhargavaraam29cloud-web/harness-azure-poc` |
| Authentication | Username and Token |
| Username | `bhargavaraam29cloud-web` |
| Personal Access Token | select **`github_pat`** from secrets dropdown |
| Enable API access | Yes |
| API Authentication Token | same `github_pat` secret |
| Connect via | Harness Platform |

Click **Save and Continue** → **Test Connection** → wait for green ✅ → **Finish**

---

#### Connector 2 — Azure (`azure_sp_connector`)

| Field | Value |
|---|---|
| Type | Azure |
| Name | `azure_sp_connector` |
| Azure Environment | Azure Global Cloud |
| Authentication | Service Principal |
| Tenant ID | `73075061-0c0e-4518-bb0f-9a70320a3354` |
| Application / Client ID | `34d460ab-83af-40ea-bad2-b7f3fd6d5afa` |
| Client Secret | select **`azure_client_secret`** from secrets |
| Subscription ID | `8e4b37d6-4aa9-408d-b5ee-f5d2ef51d314` |
| Connect via | Harness Delegate → select **`helm-delegate`** |

> Note: You will select `helm-delegate` here after deploying it in Step 3.3.
> Come back and finish this connector after the Delegate is Connected.

---

#### Connector 3 — ACR (`acr_connector`)

| Field | Value |
|---|---|
| Type | Docker Registry |
| Name | `acr_connector` |
| Docker Registry URL | `https://harnesspoc7058.azurecr.io` |
| Authentication | Username and Password |
| Username | `harnesspoc7058` |
| Password | select **`azure_client_secret`** from secrets |
| Connect via | Harness Delegate → **`helm-delegate`** |

> Deploy the Delegate (Step 3.3) first, then come back and test this connector.

---

#### Connector 4 — AKS Kubernetes (`aks_k8s_connector`)

| Field | Value |
|---|---|
| Type | Kubernetes Cluster |
| Name | `aks_k8s_connector` |
| Connection Mode | Use credentials of a specific Harness Delegate |
| Delegate | **`helm-delegate`** |

Click **Save and Continue** → **Test** → ✅ **Finish**

---

### Step 3.3 — Deploy the Harness Delegate into AKS

**What:** The Delegate is a pod running inside your AKS cluster.
It polls Harness for deployment tasks and runs kubectl inside the cluster.
No inbound ports needed — it connects outbound to Harness on port 443.

#### Get Delegate token from Harness UI:

1. Click **Account Settings** (gear icon, top left)
2. Click **Account Resources** → **Delegates**
3. Click **Tokens** tab → **+ New Token**
4. Name: `helm-delegate-token`
5. Click **Apply**
6. **Copy the token** shown in the dialog

#### Get your Harness Account ID:

1. In Harness, click **Account Settings** → **Overview**
2. Copy the **Account ID** shown at the top

#### Run the Helm install command in your terminal:

```bash
# Add the Harness Helm chart repository
helm repo add harness-delegate https://app.harness.io/storage/harness-download/delegate-helm-chart/
helm repo update

# Deploy the Delegate into your AKS cluster
# Replace <ACCOUNT_ID> and <DELEGATE_TOKEN> with your actual values
helm upgrade -i helm-delegate harness-delegate/harness-delegate-ng \
  --namespace harness-delegate-ng \
  --set delegateName=helm-delegate \
  --set accountId=<ACCOUNT_ID> \
  --set delegateToken=<DELEGATE_TOKEN> \
  --set managerEndpoint=https://app.harness.io \
  --set delegateDockerImage=harness/delegate:latest \
  --set replicas=1
```

#### Verify the Delegate is running:

```bash
# Check the Delegate pod is Running
kubectl get pods -n harness-delegate-ng
# Expected:
# NAME                            READY   STATUS    RESTARTS
# helm-delegate-xxx-yyy           1/1     Running   0
```

#### Verify in Harness UI:

1. Go back to **Account Settings** → **Delegates**
2. Wait 60 seconds
3. You should see `helm-delegate` with a green **Connected** badge
4. Heartbeat shows **"15 seconds ago"**

---

### Step 3.4 — Create Service, Environment & Infrastructure

**What:**
- **Service** = WHAT to deploy (links to GitHub manifests)
- **Environment** = WHERE to deploy (Production)
- **Infrastructure** = the actual AKS cluster and namespace

#### Create Service:

1. In Harness, switch to **Continuous Delivery** module (top-left dropdown)
2. Click **Services** → **+ New Service**
3. Name: `harness_poc_service` → **Save**
4. Under **Manifests** → **+ Add Manifest** → **Kubernetes Manifest**
5. Select Connector: `github_connector`
6. Manifest Format: **YAML**
7. Branch: `main`
8. File paths: Add `k8s/deployment.yaml` and `k8s/service.yaml`
9. Click **Submit** → **Save**

#### Create Environment + Infrastructure:

1. Click **Environments** → **+ New Environment**
2. Name: `Production` | Type: **Production** → **Save**
3. Inside Production → **Infrastructure Definitions** → **+ New Infrastructure**
4. Name: `aks_infra`
5. Type: **Kubernetes**
6. Connector: `aks_k8s_connector`
7. Namespace: `harness-poc`
8. Click **Save**

---

## Phase 4: Create and Run the Pipeline

### Step 4.1 — Create the Pipeline

1. In CD module, click **Pipelines** in left sidebar
2. Click **+ Create a Pipeline**
3. Name: `Harness Azure POC Deployment` → click **Start**
4. In the pipeline studio, click the **YAML** toggle at top right
5. Delete all default content in the editor
6. Open `.harness/pipeline.yaml` from this repo
7. Paste the entire content into the Harness YAML editor
8. Click **Save** at the top right

### Step 4.2 — Run the Pipeline

1. Click the blue **Run** button (top right)
2. A dialog appears — click **Run Pipeline** to confirm
3. Watch the pipeline visual graph turn green stage by stage
4. Steps you will see:
   - **Initialize** — Harness sets up the execution context
   - **Fetch Files** — Fetches `deployment.yaml` and `service.yaml` from GitHub
   - **Rolling Deploy to AKS** — kubectl apply runs via helm-delegate
   - **Verify Steady State** — Harness waits for pods to reach Running/Ready
5. On success: green **EXECUTION SUCCEEDED** banner appears

---

## Phase 5: Validate the Deployment

### Get the Public IP

```bash
# Check the service — wait for EXTERNAL-IP to appear (takes ~2 min)
kubectl get svc harness-poc-service -n harness-poc

# Example output:
# NAME                  TYPE           CLUSTER-IP    EXTERNAL-IP      PORT(S)
# harness-poc-service   LoadBalancer   10.0.100.50   <YOUR-IP>        80/TCP
```

```bash
# Test with curl — you should see HTML response
curl http://<YOUR-EXTERNAL-IP>/

# Test the health endpoint
curl http://<YOUR-EXTERNAL-IP>/health
# Expected: {"status":"ok","hostname":"harness-poc-app-xxx",...}
```

```bash
# Confirm pods are healthy
kubectl get pods -n harness-poc
# Expected:
# NAME                             READY   STATUS    RESTARTS
# harness-poc-app-xxxxxxxxx-xxxxx   1/1     Running   0
```

### Check Harness Dashboard

1. In Harness → **Pipelines** → click your pipeline → **Execution History**
2. Click the latest execution
3. Verify: **Status: EXECUTION SUCCEEDED**
4. Duration should be around **2-3 minutes**

---

## Phase 6: Test Auto-Rollback

### Trigger a Failed Deployment

```bash
# Edit deployment.yaml — set a broken image to simulate failure
# Change the image line to a non-existent image:
#   image: nginx:alpine
# →  image: nginx:this-tag-does-not-exist

# Commit and push
git add k8s/deployment.yaml
git commit -m "Test: use invalid image to trigger rollback"
git push origin main
```

1. In Harness UI, manually run the pipeline again
2. The **Rolling Deploy** step will fail (image pull error)
3. Watch **Rollback Rollout** step execute automatically
4. Pods revert to previous working version
5. Status: **ROLLBACK SUCCEEDED**

---

## Cleanup (When Done)

```bash
# Delete all Azure resources at once
az group delete --name harness-poc-rg --yes --no-wait

echo "All Azure resources deleted."
```

---

## Quick Reference — All Azure Resource Details

| Resource | Name | Value |
|---|---|---|
| Resource Group | `harness-poc-rg` | Region: westus2 |
| Container Registry | `harnesspoc7058` | `harnesspoc7058.azurecr.io` |
| AKS Cluster | `harness-poc-aks` | 1 node, Standard_D2s_v3 |
| Service Principal | `harness-poc-sp` | Client ID: `34d460ab-83af-40ea-bad2-b7f3fd6d5afa` |
| Subscription ID | — | `8e4b37d6-4aa9-408d-b5ee-f5d2ef51d314` |
| Tenant ID | — | `73075061-0c0e-4518-bb0f-9a70320a3354` |
| App Namespace | `harness-poc` | — |
| Delegate Namespace | `harness-delegate-ng` | — |

## Quick Reference — Harness Entities

| Entity | Type | Name / Identifier |
|---|---|---|
| Secret 1 | Secret Text | `azure_client_secret` |
| Secret 2 | Secret Text | `github_pat` |
| Connector 1 | GitHub | `github_connector` |
| Connector 2 | Azure | `azure_sp_connector` |
| Connector 3 | Docker Registry | `acr_connector` |
| Connector 4 | Kubernetes | `aks_k8s_connector` |
| Delegate | Kubernetes Pod | `helm-delegate` |
| Service | CD Service | `harness_poc_service` |
| Environment | Production | `Production` |
| Infrastructure | AKS | `aks_infra` |
| Pipeline | CD Pipeline | `Harness Azure POC Deployment` |
