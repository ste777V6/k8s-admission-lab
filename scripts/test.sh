#!/usr/bin/env bash
# Apply each test Pod and check the admission decision against the expectation.
# Exit code 0 only if all four cases behave as expected.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
[[ -f build/pods.yaml ]] || bash scripts/render.sh

declare -A EXPECT=( [signed]=admit [unsigned]=deny [wrong-identity]=deny [unsigned-sandbox]=admit )
ORDER=(signed unsigned wrong-identity unsigned-sandbox)
fail=0

# Split the multi-document file into one file per Pod name.
tmp="$(mktemp -d)"
awk -v dir="$tmp" '
  /^---/ {n++; next}
  {print > (dir "/doc" n ".yaml")}
' build/pods.yaml

for name in "${ORDER[@]}"; do
  file="$(grep -l "^  name: ${name}$" "$tmp"/doc*.yaml)"
  ns="$(awk '/^  namespace:/ {print $2; exit}' "$file")"
  kubectl delete pod "$name" -n "$ns" --ignore-not-found --wait=false >/dev/null 2>&1
  out="$(kubectl apply -f "$file" 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then got=admit; else got=deny; fi
  if [[ "$got" == "${EXPECT[$name]}" ]]; then
    printf 'PASS  %-17s expected=%-5s got=%s\n' "$name" "${EXPECT[$name]}" "$got"
  else
    printf 'FAIL  %-17s expected=%-5s got=%s\n' "$name" "${EXPECT[$name]}" "$got"; fail=1
  fi
  [[ "$got" == deny ]] && echo "      reason: $(echo "$out" | tr '\n' ' ' | cut -c1-400)"
  if [[ "$name" == signed && "$got" == admit ]]; then
    img="$(kubectl get pod signed -n prod -o jsonpath='{.spec.containers[0].image}')"
    echo "      image after admission: $img"
    [[ "$img" == *@sha256:* ]] || { echo "FAIL  tag was not rewritten to a digest"; fail=1; }
  fi
done
rm -rf "$tmp"
exit $fail
