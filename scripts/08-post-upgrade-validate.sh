#!/usr/bin/env bash
# Automates Category A-C of docs/04-SOP-Postupgrade-Validation.md.
# Categories D (mirror hygiene) and E (backup/docs) still require the
# manual steps described in that document.
#
# Usage: ./08-post-upgrade-validate.sh <expected-target-version>
set -uo pipefail

EXPECTED="${1:?expected target version required, e.g. 4.18.52}"
PASS=0
FAIL=0

check() {
  local desc="$1"; shift
  if "$@"; then echo "[PASS] $desc"; PASS=$((PASS+1));
  else echo "[FAIL] $desc"; FAIL=$((FAIL+1)); fi
}

echo "### Category A — Platform version & health ###"
CURRENT_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
echo "Desired version: $CURRENT_VERSION (expected: $EXPECTED)"
check "ClusterVersion matches expected target" bash -c "[ '$CURRENT_VERSION' = '$EXPECTED' ]"

AVAILABLE=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
PROGRESSING=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')
check "ClusterVersion Available=True"    bash -c "[ '$AVAILABLE' = 'True' ]"
check "ClusterVersion Progressing=False" bash -c "[ '$PROGRESSING' = 'False' ]"

LAST_STATE=$(oc get clusterversion version -o jsonpath='{.status.history[0].state}')
check "Latest history entry state=Completed" bash -c "[ '$LAST_STATE' = 'Completed' ]"

DEGRADED_CO=$(oc get co -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' | awk '$2=="True"{print $1}')
check "No degraded ClusterOperators" bash -c "[ -z '$DEGRADED_CO' ]"
[ -n "$DEGRADED_CO" ] && echo "  Degraded: $DEGRADED_CO"

MCP_BAD=$(oc get mcp --no-headers | awk '$2!="True" || $3!="False" || $4!="False"{print $1}')
check "All MachineConfigPools steady/updated" bash -c "[ -z '$MCP_BAD' ]"
[ -n "$MCP_BAD" ] && echo "  Not steady: $MCP_BAD"

NOT_READY=$(oc get nodes --no-headers | grep -v -E '\sReady(\s|$)' | wc -l)
check "All nodes Ready" bash -c "[ '$NOT_READY' -eq 0 ]"

echo
echo "### Category B — Workload health ###"
BAD_PODS=$(oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers)
if [ -n "$BAD_PODS" ]; then
  echo "[WARN] Review these pods:"
  echo "$BAD_PODS"
else
  echo "[PASS] No unexpected non-Running pods"; PASS=$((PASS+1))
fi

echo
echo "### Category C — Operator/OLM health ###"
oc get csv -A --no-headers 2>/dev/null | awk '{print $1, $2, $4, $5}' | grep -iE 'metallb|lvms' || echo "(no matching CSVs found — check operator names for this cluster)"
BAD_SUB=$(oc get subscriptions -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.status.state}{"\n"}{end}' 2>/dev/null | grep -v -iE 'atlatestknown|none' )
echo "Subscription states:"
echo "$BAD_SUB"

echo
echo "SUMMARY: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
