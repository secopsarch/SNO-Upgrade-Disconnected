#!/usr/bin/env bash
# Gate 0 + Gate 1 — Access & tooling / baseline health check.
#
# Run from the workstation with KUBECONFIG already pointed at cluster #2.
#
# Usage: ./00-preflight-check.sh [NODE_NAME]
#   NODE_NAME defaults to the first node returned by `oc get nodes`.
set -uo pipefail

PASS=0
FAIL=0

hr() { printf '%s\n' "----------------------------------------------------------------------"; }
section() { hr; printf '## %s\n' "$1"; hr; }
check() {
  local desc="$1"; shift
  if "$@"; then
    printf '[PASS] %s\n' "$desc"; PASS=$((PASS+1))
  else
    printf '[FAIL] %s\n' "$desc"; FAIL=$((FAIL+1))
  fi
}

section "Gate 0 — Access & tooling"
command -v oc >/dev/null 2>&1 && oc version || true
check "oc CLI available"        bash -c 'command -v oc >/dev/null'
check "podman CLI available"    bash -c 'command -v podman >/dev/null'
check "skopeo CLI available"    bash -c 'command -v skopeo >/dev/null'
if ! command -v oc-mirror >/dev/null 2>&1; then
  echo "[INFO] oc-mirror not found on PATH standalone; 'oc mirror' plugin may still work — checking..."
fi
check "oc mirror plugin responds" bash -c 'oc mirror --help >/dev/null 2>&1'
check "API server reachable"    bash -c 'oc whoami --show-server >/dev/null 2>&1'
oc whoami --show-server 2>/dev/null || true

section "Gate 1 — Cluster baseline health"
echo "--- ClusterVersion ---"
oc get clusterversion version -o wide 2>&1
CV_AVAILABLE=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
CV_PROGRESSING=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)
CV_FAILING=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Failing")].status}' 2>/dev/null)
check "ClusterVersion Available=True"     bash -c "[ '$CV_AVAILABLE' = 'True' ]"
check "ClusterVersion Progressing=False"  bash -c "[ '$CV_PROGRESSING' = 'False' ]"
check "ClusterVersion Failing=False"      bash -c "[ '$CV_FAILING' != 'True' ]"

echo "--- Nodes ---"
oc get nodes -o wide 2>&1
NOT_READY=$(oc get nodes --no-headers 2>/dev/null | grep -v -E '\sReady(\s|$)' | wc -l)
check "All nodes Ready (no SchedulingDisabled/NotReady)" bash -c "[ '$NOT_READY' -eq 0 ]"

echo "--- ClusterOperators ---"
oc get clusteroperators 2>&1
DEGRADED_CO=$(oc get co -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' 2>/dev/null | awk '$2=="True"{print $1}')
if [ -n "$DEGRADED_CO" ]; then
  echo "[FAIL] Degraded ClusterOperators: $DEGRADED_CO"; FAIL=$((FAIL+1))
else
  echo "[PASS] No degraded ClusterOperators"; PASS=$((PASS+1))
fi

echo "--- MachineConfigPools ---"
oc get mcp 2>&1
MCP_BAD=$(oc get mcp --no-headers 2>/dev/null | awk '$2!="True" || $3!="False" || $4!="False"{print $1}')
if [ -n "$MCP_BAD" ]; then
  echo "[FAIL] MCP not in steady state: $MCP_BAD"; FAIL=$((FAIL+1))
else
  echo "[PASS] All MachineConfigPools updated/steady"; PASS=$((PASS+1))
fi

echo "--- Non-Running/Non-Succeeded pods ---"
BAD_PODS=$(oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null)
if [ -n "$BAD_PODS" ]; then
  echo "$BAD_PODS"
  echo "[WARN] Review these before proceeding (may be expected, e.g. debug pods)"
else
  echo "[PASS] No unexpected non-Running pods"; PASS=$((PASS+1))
fi

echo "--- Recent events (last 20) ---"
oc get events -A --sort-by='.lastTimestamp' 2>/dev/null | tail -20

section "Node -> Registry connectivity (informational, needs Gate 2 registry host first)"
NODE_NAME="${1:-$(oc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)}"
if [ -n "$NODE_NAME" ]; then
  echo "Using node: $NODE_NAME"
  oc debug node/"$NODE_NAME" -- chroot /host cat /etc/containers/registries.conf 2>&1 | head -40
fi

hr
echo "SUMMARY: PASS=$PASS FAIL=$FAIL"
hr
if [ "$FAIL" -gt 0 ]; then
  echo "One or more gates failed. Resolve before proceeding to Gate 2."
  exit 1
fi
exit 0
