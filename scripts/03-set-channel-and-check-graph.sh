#!/usr/bin/env bash
# Gate 4 — Set the update channel (if needed) and read the recommended
# target version from the Cincinnati graph. Never hard-code a version;
# this script only ever prints what the cluster itself recommends.
#
# Usage: ./03-set-channel-and-check-graph.sh [channel]
#   channel defaults to "stable-4.18" — change if a different channel is
#   correct for this cluster (check Gate 4's documentation first).
set -euo pipefail

CHANNEL="${1:-stable-4.18}"

CURRENT_CHANNEL=$(oc get clusterversion version -o jsonpath='{.spec.channel}' 2>/dev/null)
echo "Current channel: '${CURRENT_CHANNEL:-<unset>}'"

if [ "$CURRENT_CHANNEL" != "$CHANNEL" ]; then
  echo "Setting channel to '$CHANNEL' ..."
  oc patch clusterversion version --type=merge -p "{\"spec\":{\"channel\":\"${CHANNEL}\"}}"
else
  echo "Channel already set to '$CHANNEL'."
fi

echo "Waiting for RetrievedUpdates=True (timeout 5 min) ..."
for i in $(seq 1 30); do
  STATUS=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="RetrievedUpdates")].status}' 2>/dev/null)
  if [ "$STATUS" = "True" ]; then
    echo "RetrievedUpdates=True after $((i*10))s."
    break
  fi
  sleep 10
done

echo
echo "=== oc adm upgrade ==="
oc adm upgrade || true

echo
echo "=== Available updates (recommended) ==="
oc get clusterversion version -o jsonpath='{range .status.availableUpdates[*]}{.version}{"  "}{.image}{"\n"}{end}' 2>/dev/null

echo
echo "=== Conditional updates (require risk acknowledgement — review manually) ==="
oc get clusterversion version -o jsonpath='{range .status.conditionalUpdates[*]}{.release.version}{"  "}{.release.image}{"\n"}{end}' 2>/dev/null

echo
echo "ACTION REQUIRED: record the exact recommended version above. Use it — and"
echo "only it — as the <TARGET_VERSION> for Gate 5 validation and for the"
echo "'oc adm upgrade --to=' command in the execution flow."
