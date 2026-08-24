#!/usr/bin/env bash
# Merge local registry credentials into openshift-config/pull-secret.
# Usage: ./merge-pull-secret.sh <registry_host:port> <user> <pass>
set -euo pipefail

REG="${1:?registry host:port}"
USER="${2:?username}"
PASS="${3:?password}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

oc get secret pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "$TMP/pull.json"

AUTH=$(echo -n "${USER}:${PASS}" | base64 -w0)
jq --arg reg "$REG" --arg auth "$AUTH" \
  '.auths[$reg] = {"auth": $auth}' "$TMP/pull.json" > "$TMP/pull-merged.json"

oc set data secret/pull-secret -n openshift-config \
  --from-file=.dockerconfigjson="$TMP/pull-merged.json"

echo "Updated pull-secret with auth for ${REG}"
oc get secret pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq '.auths | keys'
