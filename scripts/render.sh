#!/usr/bin/env bash
# Fill in the templates from lab.env -> build/
set -euo pipefail
cd "$(dirname "$0")/.."
# Environment variables win over lab.env (CI sets them).
env_owner="${GH_OWNER:-}"; env_repo="${GH_REPO:-}"
# shellcheck disable=SC1091
source lab.env
GH_OWNER="${env_owner:-$GH_OWNER}"; GH_REPO="${env_repo:-$GH_REPO}"
if [[ "${GH_OWNER}" == "CHANGE_ME" || -z "${GH_OWNER}" ]]; then
  echo "Edit lab.env first (GH_OWNER)." >&2; exit 1
fi
IMAGE_REPO="$(echo "${GH_OWNER}/${GH_REPO}" | tr '[:upper:]' '[:lower:]')"  # GHCR names are lower-case
mkdir -p build
for f in policies/verify-supply-chain.tmpl.yaml manifests/pods.tmpl.yaml; do
  out="build/$(basename "${f/.tmpl/}")"
  sed -e "s|__GH_OWNER__|${GH_OWNER}|g" -e "s|__GH_REPO__|${GH_REPO}|g" \
      -e "s|__IMAGE_REPO__|${IMAGE_REPO}|g" "$f" > "$out"
  echo "rendered $out"
done
