#!/usr/bin/env bash
# Consolidated upgrade monitoring loop — a single-pane alternative to the
# 5-terminal layout described in docs/03-SOP-Execution-Flow.md. Prefer the
# multi-pane layout for active babysitting; use this for a background
# transcript/log.
#
# Usage: ./06-monitor-upgrade.sh [interval-seconds] [logfile]
set -uo pipefail

INTERVAL="${1:-15}"
LOGFILE="${2:-upgrade-monitor-$(date +%Y%m%dT%H%M%S).log}"

echo "Logging to $LOGFILE every ${INTERVAL}s. Ctrl-C to stop."
LAST_MSG=""

{
  while true; do
    TS=$(date -Is)
    CV_LINE=$(oc get clusterversion version --no-headers 2>/dev/null)
    MSG=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}' 2>/dev/null)

    echo "=== $TS ==="
    echo "$CV_LINE"
    echo "message: $MSG"

    if [ "$MSG" != "$LAST_MSG" ]; then
      echo ">>> STATUS CHANGED <<<"
      LAST_MSG="$MSG"
    fi

    # Surface anything obviously bad without spamming full output every loop.
    BAD_CO=$(oc get co -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' 2>/dev/null | awk '$2=="True"')
    if [ -n "$BAD_CO" ]; then
      echo "DEGRADED OPERATORS:"
      echo "$BAD_CO"
    fi

    BAD_PODS=$(oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null)
    if [ -n "$BAD_PODS" ]; then
      echo "NON-RUNNING PODS:"
      echo "$BAD_PODS"
    fi

    NODES=$(oc get nodes --no-headers 2>/dev/null)
    echo "$NODES"

    echo
    sleep "$INTERVAL"
  done
} | tee -a "$LOGFILE"
