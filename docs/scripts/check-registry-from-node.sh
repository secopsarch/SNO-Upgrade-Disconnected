#!/usr/bin/env bash
# Quick registry path check from an OpenShift node.
# Usage: ./check-registry-from-node.sh [node] [registry_host:port]
set -euo pipefail

NODE="${1:-$(oc get nodes -o jsonpath='{.items[0].metadata.name}')}"
REG="${2:-registry.ocp4.example.com:8443}"

echo "Checking https://${REG}/v2/ from node ${NODE}"
oc debug "node/${NODE}" -- chroot /host \
  curl -sS -o /tmp/v2.out -w "%{http_code}" "https://${REG}/v2/" | tee /tmp/code.txt
echo
CODE=$(cat /tmp/code.txt || true)
# debug pod may not persist; also run inline:
oc debug "node/${NODE}" -- chroot /host \
  curl -I "https://${REG}/v2/" || true

echo "Expected HTTP 401 Unauthorized for healthy auth-walled registry."
