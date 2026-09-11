#!/usr/bin/env bash

set -e

AWS_REGION="eu-central-1"
CLUSTER_NAME="dev-shopping-eks"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEV_DIR="${ROOT_DIR}/terraform/aws/environments/dev"
DNS_DIR="${ROOT_DIR}/terraform/aws/global/dns"

echo "=== 1. Terraform apply: AWS dev ==="
terraform -chdir="${DEV_DIR}" apply -auto-approve

echo "=== 2. Configure kubeconfig ==="
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}"

echo "=== 3. Wait for NLB hostname ==="

NLB_HOST=""

for i in {1..30}; do
  NLB_HOST="$(
    kubectl get svc ingress-nginx-controller \
      -n ingress-nginx \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
      2>/dev/null || true
  )"

  if [[ -n "${NLB_HOST}" ]]; then
    break
  fi

  echo "NLB hostname not ready yet... retry ${i}/30"
  sleep 10
done

if [[ -z "${NLB_HOST}" ]]; then
  echo "NLB hostname was not available after 5 minutes."
  exit 1
fi

echo "NLB: ${NLB_HOST}"

echo "=== 4. Update Route53 ==="
terraform -chdir="${DNS_DIR}" apply \
  -auto-approve \
  -var="nlb_dns_name=${NLB_HOST}"

echo "=== 5. Wait for ArgoCD admin password ==="

ARGOCD_PASSWORD=""

for i in {1..30}; do
  ARGOCD_PASSWORD="$(
    kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' \
      2>/dev/null | base64 -d || true
  )"

  if [[ -n "${ARGOCD_PASSWORD}" ]]; then
    break
  fi

  echo "ArgoCD password not ready yet... retry ${i}/30"
  sleep 10
done

if [[ -z "${ARGOCD_PASSWORD}" ]]; then
  echo "ArgoCD admin password was not available after 5 minutes."
  exit 1
fi

echo
echo "ArgoCD username: admin"
echo "ArgoCD password: ${ARGOCD_PASSWORD}"

echo
echo "=== Bootstrap complete ==="
echo "https://shopping.benchpressproiectradu.ro"
echo "https://argocd.benchpressproiectradu.ro"