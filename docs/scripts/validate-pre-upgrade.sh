#!/usr/bin/env bash
# Pre-upgrade health gate for disconnected SNO.
# Usage: ./validate-pre-upgrade.sh
set -euo pipefail

pass=0
fail=0

echo "===== Pre-upgrade validation $(date -Is) ====="

if ! command -v oc >/dev/null; then
  echo "FAIL  oc available"; exit 1
fi
echo "PASS  oc available"; pass=$((pass+1))

if ! oc whoami >/dev/null; then
  echo "FAIL  can authenticate"; exit 1
fi
echo "PASS  can authenticate"; pass=$((pass+1))

if ! command -v jq >/dev/null; then
  echo "FAIL  jq required"; exit 1
fi

cv_json=$(oc get clusterversion version -o json)
if jq -e '.status.conditions[] | select(.type=="Available" and .status=="True")' <<<"$cv_json" >/dev/null; then
  echo "PASS  ClusterVersion Available=True"; pass=$((pass+1))
else
  echo "FAIL  ClusterVersion Available=True"; fail=$((fail+1))
fi

if jq -e '.status.conditions[] | select(.type=="Progressing" and .status=="False")' <<<"$cv_json" >/dev/null; then
  echo "PASS  ClusterVersion Progressing=False"; pass=$((pass+1))
else
  echo "FAIL  ClusterVersion Progressing=False (upgrade may already be in progress)"; fail=$((fail+1))
fi

not_ready=$(oc get nodes --no-headers | awk '$2 !~ /^Ready$/ {print}' || true)
if [[ -z "${not_ready}" ]]; then
  echo "PASS  All nodes Ready"; pass=$((pass+1))
else
  echo "FAIL  Nodes not Ready:"; echo "$not_ready"; fail=$((fail+1))
fi

bad_co=$(oc get clusteroperators --no-headers \
  | awk '$3!="True" || $4!="False" || $5!="False" {print}' || true)
if [[ -z "${bad_co}" ]]; then
  echo "PASS  All ClusterOperators healthy"; pass=$((pass+1))
else
  echo "FAIL  Unhealthy ClusterOperators:"; echo "$bad_co"; fail=$((fail+1))
fi

bad_mcp=$(oc get mcp --no-headers \
  | awk '$3!="True" || $4!="False" || $5!="False" {print}' || true)
if [[ -z "${bad_mcp}" ]]; then
  echo "PASS  All MCP healthy"; pass=$((pass+1))
else
  echo "FAIL  Unhealthy MCP:"; echo "$bad_mcp"; fail=$((fail+1))
fi

if oc get imagecontentsourcepolicy -o name 2>/dev/null | grep -q .; then
  echo "PASS  ICSP present"; pass=$((pass+1))
else
  echo "FAIL  ICSP present"; fail=$((fail+1))
fi

if oc get cm registry-config -n openshift-config >/dev/null 2>&1; then
  echo "PASS  registry-config ConfigMap present"; pass=$((pass+1))
else
  echo "FAIL  registry-config ConfigMap present"; fail=$((fail+1))
fi

echo
echo "PASS=$pass FAIL=$fail"
if [[ "$fail" -gt 0 ]]; then
  echo "GATE FAILED — do not upgrade"
  exit 1
fi
echo "GATE PASSED — proceed to mirror validation + backup"
