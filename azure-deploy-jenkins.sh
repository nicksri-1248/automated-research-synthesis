#!/bin/bash

# Azure Deployment Script for Jenkins
# Deploys Jenkins with Python 3.11 and Azure CLI for Research Report Generation CI/CD

set -e

# Configuration
UNIQUE_SUFFIX="$(date +%s | tail -c 6)"
RESOURCE_GROUP="research-report-jenkins-rg"
LOCATION="eastus"
STORAGE_ACCOUNT="reportjenkinsstore${UNIQUE_SUFFIX}"
FILE_SHARE="jenkins-data"
ACR_NAME="reportjenkinsacr${UNIQUE_SUFFIX}"
CONTAINER_NAME="jenkins-research-report"
DNS_NAME_LABEL="jenkins-research-${UNIQUE_SUFFIX}"
JENKINS_IMAGE_NAME="custom-jenkins"
JENKINS_IMAGE_TAG="lts-git-configured"

# Subscription ID - can be passed as argument or environment variable
SUBSCRIPTION_ID="${1:-${AZURE_SUBSCRIPTION_ID}}"

echo "╔════════════════════════════════════════════════════════╗"
echo "║  Deploying Jenkins for Research Report Generation     ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

# Verify Azure login
echo "Verifying Azure login..."
if ! az account show &>/dev/null; then
    echo "Not logged in to Azure. Please run 'az login' first."
    exit 1
fi

# Set subscription if provided
if [ -n "$SUBSCRIPTION_ID" ]; then
    echo "Setting Azure subscription to: $SUBSCRIPTION_ID"
    az account set --subscription "$SUBSCRIPTION_ID"
    if [ $? -ne 0 ]; then
        echo "Failed to set subscription. Please verify the subscription ID."
        exit 1
    fi
else
    echo "ℹ️No subscription ID provided. Using current default subscription."
    CURRENT_SUB=$(az account show --query id -o tsv)
    echo "   Current subscription: $CURRENT_SUB"
fi

# Verify subscription is set correctly
CURRENT_SUB=$(az account show --query id -o tsv)
echo "Using subscription: $CURRENT_SUB"
echo ""

# Store subscription ID for use in commands
if [ -z "$SUBSCRIPTION_ID" ]; then
    SUBSCRIPTION_ID="$CURRENT_SUB"
fi

# Create Resource Group
echo "Creating Resource Group: $RESOURCE_GROUP..."
az group create --name $RESOURCE_GROUP --location $LOCATION --subscription "$SUBSCRIPTION_ID"

# Create Storage Account
echo "Creating Storage Account: $STORAGE_ACCOUNT..."
az storage account create \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT \
  --location $LOCATION \
  --sku Standard_LRS \
  --subscription "$SUBSCRIPTION_ID"

# Get Storage Account Key
STORAGE_KEY=$(az storage account keys list \
  --resource-group $RESOURCE_GROUP \
  --account-name $STORAGE_ACCOUNT \
  --subscription "$SUBSCRIPTION_ID" \
  --query '[0].value' -o tsv)

# Create File Share
echo "Creating File Share: $FILE_SHARE..."
az storage share create \
  --name $FILE_SHARE \
  --account-name $STORAGE_ACCOUNT \
  --account-key $STORAGE_KEY \
  --subscription "$SUBSCRIPTION_ID"

# Create Azure Container Registry
echo "Creating Container Registry: $ACR_NAME..."
az acr create \
  --resource-group $RESOURCE_GROUP \
  --name $ACR_NAME \
  --sku Basic \
  --admin-enabled true \
  --subscription "$SUBSCRIPTION_ID"

# The Jenkins image is built and pushed by the "Build and Push Jenkins Image"
# GitHub Actions workflow (.github/workflows/build-jenkins-image.yml) — not
# locally and not via ACR Tasks (ACR Tasks is disabled on this subscription).
# Verify the image has already landed in the registry before deploying it.
echo "Checking for image ${JENKINS_IMAGE_NAME}:${JENKINS_IMAGE_TAG} in $ACR_NAME..."
if ! az acr repository show \
  --name $ACR_NAME \
  --image ${JENKINS_IMAGE_NAME}:${JENKINS_IMAGE_TAG} \
  --subscription "$SUBSCRIPTION_ID" &>/dev/null; then
  echo "Image ${JENKINS_IMAGE_NAME}:${JENKINS_IMAGE_TAG} not found in $ACR_NAME."
  echo ""
  echo "Build it first by running the 'Build and Push Jenkins Image' GitHub Actions"
  echo "workflow (Actions tab > Build and Push Jenkins Image > Run workflow), then"
  echo "re-run this script."
  exit 1
fi
echo "Image found."

# Get ACR credentials for container deployment
echo "Retrieving ACR credentials..."
ACR_USERNAME=$(az acr credential show \
  --name $ACR_NAME \
  --subscription "$SUBSCRIPTION_ID" \
  --query username -o tsv)

ACR_PASSWORD=$(az acr credential show \
  --name $ACR_NAME \
  --subscription "$SUBSCRIPTION_ID" \
  --query passwords[0].value -o tsv)

# Deploy Jenkins Container using custom image
echo "Deploying Jenkins Container..."
az container create \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME \
  --image ${ACR_NAME}.azurecr.io/${JENKINS_IMAGE_NAME}:${JENKINS_IMAGE_TAG} \
  --registry-login-server ${ACR_NAME}.azurecr.io \
  --registry-username $ACR_USERNAME \
  --registry-password $ACR_PASSWORD \
  --os-type Linux \
  --dns-name-label $DNS_NAME_LABEL \
  --ports 8080 \
  --cpu 2 \
  --memory 4 \
  --azure-file-volume-account-name $STORAGE_ACCOUNT \
  --azure-file-volume-account-key $STORAGE_KEY \
  --azure-file-volume-share-name $FILE_SHARE \
  --azure-file-volume-mount-path //var/jenkins_home \
  --environment-variables JAVA_OPTS="-Djenkins.install.runSetupWizard=true" \
  --subscription "$SUBSCRIPTION_ID"

# Wait for deployment
echo "Waiting for Jenkins to deploy..."
sleep 10

# Get Jenkins URL
JENKINS_URL=$(az container show \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME \
  --subscription "$SUBSCRIPTION_ID" \
  --query ipAddress.fqdn -o tsv)

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║           Deployment Complete!                         ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "Jenkins URL: http://$JENKINS_URL:8080"
echo ""
echo "Wait 2-3 minutes for Jenkins to fully start, then run:"
echo ""
echo "az container exec \\"
echo "  --resource-group $RESOURCE_GROUP \\"
echo "  --name $CONTAINER_NAME \\"
echo "  --exec-command 'cat /var/jenkins_home/secrets/initialAdminPassword'"
echo ""
echo "Save this information for the next steps!"