#!/usr/bin/env bash
# Create a kind cluster, install Kyverno (pinned), apply the policy.
# Requires: docker, kind, kubectl, helm.  Pass --no-cluster to reuse the
# current kubectl context (used in CI, where helm/kind-action creates it).
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=admission-lab
KYVERNO_CHART_VERSION=3.9.2   # Kyverno app v1.19.2

if [[ "${1:-}" != "--no-cluster" ]]; then
  kind create cluster --name "$CLUSTER" --wait 120s
fi

helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version "$KYVERNO_CHART_VERSION" --wait --timeout 5m

bash scripts/render.sh
kubectl apply -f manifests/namespaces.yaml
kubectl apply -f build/verify-supply-chain.yaml
kubectl wait --for=condition=Ready clusterpolicy/verify-supply-chain --timeout=120s
echo "Kyverno installed and policy Ready."
