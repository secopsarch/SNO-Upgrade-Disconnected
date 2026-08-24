#!/usr/bin/env bash
# Step 3 of the execution flow — issue the upgrade using the version the
# cluster itself recommended (never a hard-coded value).
#
# Usage: ./05-start-upgrade.sh <version-from-oc-adm-upgrade>
set -euo pipefail

TARGET="${1:?target version required, e.g. 4.18.52 -- copy it from 'oc adm upgrade' output}"

CURRENT=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
echo "Current desired version: $CURRENT"
echo "Requested target version: $TARGET"

echo
echo "Recommended updates currently offered by the cluster:"
oc get clusterversion version -o jsonpath='{range .status.availableUpdates[*]}{.version}{"\n"}{end}' 2>/dev/null

read -r -p "Proceed with 'oc adm upgrade --to=${TARGET}'? [y/N] " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "Aborted."
  exit 1
fi

oc adm upgrade --to="$TARGET"

echo
echo "Upgrade issued. Immediately switch to monitoring:"
echo "  bash scripts/06-monitor-upgrade.sh"
