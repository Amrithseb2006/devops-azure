#!/usr/bin/env bash
# Creates everything in Azure: resource group, VNet, 2 NSGs, 2 Ubuntu VMs (Jenkins + App/Kubernetes).
# Run from your laptop (Linux/macOS/WSL/Git Bash) after:  az login
#
#   export MY_IP="<your public IP>"      # get it from https://ifconfig.me  (NOT needed to be a CIDR)
#   bash azure/provision.sh
#
# Optional overrides: LOCATION, VM_SIZE, RG, KEY
set -euo pipefail

: "${MY_IP:?Set MY_IP first, e.g. export MY_IP=203.0.113.7}"
RG="${RG:-devops-cia-rg}"
LOCATION="${LOCATION:-centralindia}"
VM_SIZE="${VM_SIZE:-Standard_B2s}"          # 2 vCPU / 4 GB. If 'not available', see AZURE-DEPLOYMENT.md section 3.3
KEY="${KEY:-$HOME/.ssh/azure_devops_key}"
IMAGE="Canonical:ubuntu-24_04-lts:server:latest"
ADMIN="azureuser"

if [ ! -f "$KEY" ]; then
  echo ">> Generating SSH key $KEY"
  mkdir -p "$(dirname "$KEY")"
  ssh-keygen -t rsa -b 4096 -f "$KEY" -N "" -C "azure-devops-cia"
fi

echo ">> Resource group"
az group create -n "$RG" -l "$LOCATION" -o none

echo ">> Virtual network (10.0.0.0/16, subnet 10.0.1.0/24)"
az network vnet create -g "$RG" -n devops-vnet --address-prefix 10.0.0.0/16 \
  --subnet-name devops-subnet --subnet-prefix 10.0.1.0/24 -o none

echo ">> Network security groups (firewalls)"
az network nsg create -g "$RG" -n jenkins-nsg -o none
az network nsg rule create -g "$RG" --nsg-name jenkins-nsg -n ssh-from-me --priority 100 \
  --direction Inbound --access Allow --protocol Tcp --destination-port-ranges 22 \
  --source-address-prefixes "$MY_IP" -o none
az network nsg rule create -g "$RG" --nsg-name jenkins-nsg -n jenkins-ui-from-me --priority 110 \
  --direction Inbound --access Allow --protocol Tcp --destination-port-ranges 8080 \
  --source-address-prefixes "$MY_IP" -o none

az network nsg create -g "$RG" -n app-nsg -o none
az network nsg rule create -g "$RG" --nsg-name app-nsg -n ssh-from-me --priority 100 \
  --direction Inbound --access Allow --protocol Tcp --destination-port-ranges 22 \
  --source-address-prefixes "$MY_IP" -o none
az network nsg rule create -g "$RG" --nsg-name app-nsg -n http-from-internet --priority 110 \
  --direction Inbound --access Allow --protocol Tcp --destination-port-ranges 80 \
  --source-address-prefixes Internet -o none
# Jenkins VM -> App VM SSH (port 22) is already allowed by Azure's default AllowVnetInBound rule.

echo ">> VM 1: jenkins-vm (10.0.1.4)"
az vm create -g "$RG" -n jenkins-vm --image "$IMAGE" --size "$VM_SIZE" \
  --admin-username "$ADMIN" --ssh-key-values "${KEY}.pub" --authentication-type ssh \
  --vnet-name devops-vnet --subnet devops-subnet --private-ip-address 10.0.1.4 \
  --nsg jenkins-nsg --nsg-rule NONE \
  --public-ip-sku Standard --public-ip-address-allocation static \
  --os-disk-size-gb 30 -o none

echo ">> VM 2: app-vm (10.0.1.5) - will run Kubernetes (k3s)"
az vm create -g "$RG" -n app-vm --image "$IMAGE" --size "$VM_SIZE" \
  --admin-username "$ADMIN" --ssh-key-values "${KEY}.pub" --authentication-type ssh \
  --vnet-name devops-vnet --subnet devops-subnet --private-ip-address 10.0.1.5 \
  --nsg app-nsg --nsg-rule NONE \
  --public-ip-sku Standard --public-ip-address-allocation static \
  --os-disk-size-gb 30 -o none

JENKINS_IP=$(az vm show -d -g "$RG" -n jenkins-vm --query publicIps -o tsv)
APP_IP=$(az vm show -d -g "$RG" -n app-vm --query publicIps -o tsv)

cat <<MSG

==================== DONE ====================
Jenkins VM  public IP : $JENKINS_IP     private IP: 10.0.1.4
App VM      public IP : $APP_IP     private IP: 10.0.1.5

SSH to Jenkins : ssh -i $KEY $ADMIN@$JENKINS_IP
SSH to App VM  : ssh -i $KEY $ADMIN@$APP_IP
Jenkins UI     : http://$JENKINS_IP:8080   (after you install Jenkins)
App (later)    : http://$APP_IP/health
==============================================
MSG
