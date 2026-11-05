#!/usr/bin/env bash
# Create a kind cluster, install Kyverno (pinned), apply the policy.
# Requires: docker, kind, kubectl, helm.  Pass --no-cluster to reuse the
# current kubectl context (used in CI, where helm/kind-action creates it).
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=admission-lab
KYVERNO_CHART_VERSION=3.9.2   # Kyverno app v1.19.2
# Kyverno loads each verified attestation into its policy context, capped by
# config.maxContextSize (default 2Mi). The SPDX SBOM attestation of the
# supply-chain image is ~2.2 MB (first e2e run: "context size limit exceeded:
# 2265002 bytes exceeds limit of 2097152 bytes"), so raise the cap with headroom.
MAX_CONTEXT_SIZE=8Mi

if [[ "${1:-}" != "--no-cluster" ]]; then
  kind create cluster --name "$CLUSTER" --wait 120s
fi

helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version "$KYVERNO_CHART_VERSION" \
  --set-string config.maxContextSize="$MAX_CONTEXT_SIZE" \
  --wait --timeout 5m

bash scripts/render.sh
kubectl apply -f manifests/namespaces.yaml
# `helm --wait` returns when the Kyverno pod is Ready, but its webhook server can
# still be waiting for its TLS certificate. Kyverno validates policies through its
# own (fail-closed) webhook, so applying too early fails with "connection refused".
# Retry until the webhook answers (seen in e2e run 2, 2026-11-05).
for attempt in $(seq 1 24); do
  if kubectl apply -f build/verify-supply-chain.yaml; then
    break
  fi
  if [[ "$attempt" -eq 24 ]]; then
    echo "Kyverno webhook still not reachable after 2 minutes." >&2; exit 1
  fi
  echo "Kyverno webhook not ready yet; retrying in 5s ($attempt/24)..."
  sleep 5
done
kubectl wait --for=condition=Ready clusterpolicy/verify-supply-chain --timeout=120s
echo "Kyverno config maxContextSize: $(kubectl get configmap kyverno -n kyverno -o jsonpath='{.data.maxContextSize}')"
echo "Kyverno installed and policy Ready."
