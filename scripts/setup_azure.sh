#!/bin/bash
# ================================================================
# FILE: scripts/setup_azure.sh
# PURPOSE:
#   One-time infrastructure provisioning script.
#   Run this BEFORE setting up Harness connectors.
#   It creates every Azure resource the POC needs.
#
# WHAT IT CREATES (in order):
#   1. Register Azure resource providers (ACR + AKS features)
#   2. Resource Group: harness-poc-rg  (westus2)
#   3. Container Registry: harnesspoc7058  (Basic SKU)
#   4. AKS Cluster: harness-poc-aks  (1 node, Standard_D2s_v3)
#   5. Service Principal: harness-poc-sp  (Contributor + AcrPush)
#   6. Kubeconfig download  (so kubectl works locally)
#   7. Kubernetes namespaces: harness-poc + harness-delegate-ng
#
# HOW TO RUN:
#   chmod +x scripts/setup_azure.sh
#   ./scripts/setup_azure.sh
#
# PREREQUISITES:
#   - Azure CLI installed  (brew install azure-cli)
#   - Already logged in   (az login)
#   - kubectl installed   (brew install kubectl)
#
# OUTPUTS:
#   Credentials are printed at the end AND saved to
#   .harness_azure_creds.env — DO NOT commit this file.
# ================================================================

set -euo pipefail
# set -e  → stop immediately on any error
# set -u  → treat unset variables as errors
# set -o pipefail → catch errors inside piped commands

# ----------------------------------------------------------------
# CONFIGURATION — matches exactly what the presentation documents
# ----------------------------------------------------------------
RESOURCE_GROUP="harness-poc-rg"
LOCATION="westus2"
ACR_NAME="harnesspoc7058"
AKS_CLUSTER="harness-poc-aks"
AKS_NODE_COUNT=1
AKS_NODE_SIZE="Standard_D2s_v3"
SP_NAME="harness-poc-sp"
NAMESPACE_APP="harness-poc"
NAMESPACE_DELEGATE="harness-delegate-ng"

# Terminal colours for readable output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'   # No colour

step() { echo -e "\n${CYAN}[STEP] $1${NC}"; }
ok()   { echo -e "${GREEN}  ✔  $1${NC}"; }
info() { echo -e "${YELLOW}  ►  $1${NC}"; }

echo ""
echo "================================================================"
echo "  Harness Azure POC — Infrastructure Setup Script"
echo "  Resource Group : $RESOURCE_GROUP  |  Region: $LOCATION"
echo "================================================================"

# ----------------------------------------------------------------
# STEP 1: Register Azure resource providers
# Azure won't let you create ACR or AKS unless these providers
# are registered in your subscription. --wait blocks until done.
# ----------------------------------------------------------------
step "Registering Azure resource providers (ACR + AKS)..."
az provider register --namespace Microsoft.ContainerRegistry --wait
az provider register --namespace Microsoft.ContainerService  --wait
ok "Providers registered."

# ----------------------------------------------------------------
# STEP 2: Create Resource Group
# All POC resources live inside harness-poc-rg.
# If the RG already exists, this command updates its tags safely.
# ----------------------------------------------------------------
step "Creating Resource Group: $RESOURCE_GROUP in $LOCATION..."
az group create \
  --name     "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output   table
ok "Resource Group ready."

# ----------------------------------------------------------------
# STEP 3: Create Azure Container Registry (ACR)
# Stores the Docker image Harness CI builds.
# Basic SKU = cheapest option, adequate for POC workloads.
# ----------------------------------------------------------------
step "Creating Azure Container Registry: $ACR_NAME..."
az acr create \
  --name           "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --sku            Basic \
  --output         table
ok "ACR created: ${ACR_NAME}.azurecr.io"

# ----------------------------------------------------------------
# STEP 4: Create AKS Cluster
# Provisions a 1-node managed Kubernetes cluster.
# --generate-ssh-keys creates a key pair automatically if needed.
# This step takes 8-15 minutes — normal, Azure is provisioning VMs.
# ----------------------------------------------------------------
step "Creating AKS Cluster: $AKS_CLUSTER  (takes ~10 min)..."
az aks create \
  --name                  "$AKS_CLUSTER" \
  --resource-group        "$RESOURCE_GROUP" \
  --node-count            "$AKS_NODE_COUNT" \
  --node-vm-size          "$AKS_NODE_SIZE" \
  --generate-ssh-keys \
  --enable-managed-identity \
  --output                table
ok "AKS cluster ready."

# ----------------------------------------------------------------
# STEP 5: Create Service Principal (robot identity for Harness)
# Harness uses this SP to authenticate to Azure without needing
# your personal credentials. --role Contributor means the SP can
# manage resources inside harness-poc-rg only (not your whole account).
# ----------------------------------------------------------------
step "Creating Service Principal: $SP_NAME..."
SUB_ID=$(az account show --query id -o tsv)

SP_JSON=$(az ad sp create-for-rbac \
  --name   "$SP_NAME" \
  --role   Contributor \
  --scopes "/subscriptions/${SUB_ID}/resourceGroups/${RESOURCE_GROUP}" \
  --output json)

CLIENT_ID=$(echo "$SP_JSON"     | python3 -c "import sys,json; print(json.load(sys.stdin)['appId'])")
CLIENT_SECRET=$(echo "$SP_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")
TENANT_ID=$(echo "$SP_JSON"     | python3 -c "import sys,json; print(json.load(sys.stdin)['tenant'])")

# Grant AcrPush role so Harness CI can push images to ACR
ACR_ID=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
az role assignment create \
  --assignee   "$CLIENT_ID" \
  --role       AcrPush \
  --scope      "$ACR_ID" \
  --output     table

ok "Service Principal created with Contributor + AcrPush roles."

# ----------------------------------------------------------------
# STEP 6: Download kubeconfig for kubectl access
# az aks get-credentials writes the cluster connection details
# into ~/.kube/config so kubectl works without any extra setup.
# ----------------------------------------------------------------
step "Downloading AKS kubeconfig..."
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name           "$AKS_CLUSTER" \
  --overwrite-existing
ok "kubeconfig written. kubectl is now connected to $AKS_CLUSTER."

# ----------------------------------------------------------------
# STEP 7: Create Kubernetes namespaces
# harness-poc          → your app pods live here
# harness-delegate-ng  → Harness Delegate pod lives here
# Keeping them separate makes RBAC and monitoring cleaner.
# ----------------------------------------------------------------
step "Creating Kubernetes namespaces..."
kubectl create namespace "$NAMESPACE_APP"      --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$NAMESPACE_DELEGATE" --dry-run=client -o yaml | kubectl apply -f -
ok "Namespaces created: $NAMESPACE_APP, $NAMESPACE_DELEGATE"

# ----------------------------------------------------------------
# Verify: show current state
# ----------------------------------------------------------------
step "Verification — current cluster nodes and namespaces:"
kubectl get nodes
kubectl get namespaces

# ----------------------------------------------------------------
# Save credentials to env file (DO NOT commit to GitHub)
# ----------------------------------------------------------------
CREDS_FILE=".harness_azure_creds.env"
cat > "$CREDS_FILE" << EOF
# Harness Azure POC — Credentials
# Generated: $(date)
# !!! DO NOT COMMIT THIS FILE TO GITHUB !!!

SUBSCRIPTION_ID=$SUB_ID
TENANT_ID=$TENANT_ID
CLIENT_ID=$CLIENT_ID
CLIENT_SECRET=$CLIENT_SECRET
ACR_LOGIN_SERVER=${ACR_NAME}.azurecr.io
RESOURCE_GROUP=$RESOURCE_GROUP
AKS_CLUSTER=$AKS_CLUSTER
LOCATION=$LOCATION
EOF

echo ""
echo "================================================================"
echo "  CREDENTIALS FOR HARNESS CONNECTOR SETUP"
echo "================================================================"
info "Subscription ID : $SUB_ID"
info "Tenant ID       : $TENANT_ID"
info "Client ID       : $CLIENT_ID"
info "Client Secret   : $CLIENT_SECRET   ← store in Harness Secret: azure_client_secret"
info "ACR Server      : ${ACR_NAME}.azurecr.io"
echo ""
ok "All values also saved to: $CREDS_FILE"
echo ""
echo "  NEXT STEP: Open README.md and follow Phase 2 (Harness UI setup)"
echo "================================================================"
