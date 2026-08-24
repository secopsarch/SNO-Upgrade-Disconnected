#!/usr/bin/env bash
# Validate local mirror contains target release content.
# Usage: ./validate-mirror.sh <registry_host:port> <version>
# Example: ./validate-mirror.sh registry.ocp4.example.com:8443 4.18.52
set -euo pipefail

REG="${1:?registry host:port required}"
VER="${2:?version required e.g. 4.18.52}"
REPO_RELEASE="${REG}/openshift/release"
REPO_RELEASE_IMAGES="${REG}/openshift/release-images"

echo "===== Mirror validation for ${VER} on ${REG} ====="

if ! command -v skopeo >/dev/null; then
  echo "FAIL skopeo not installed on this host"
  exit 1
fi

echo "-- list-tags release-images --"
if ! skopeo list-tags "docker://${REPO_RELEASE_IMAGES}" | tee /tmp/release-images-tags.json | grep -q "${VER}"; then
  echo "FAIL ${VER} not found in ${REPO_RELEASE_IMAGES} tags"
  echo "     Mirror the release before upgrading."
  exit 1
fi
echo "PASS found ${VER} in release-images tags"

echo "-- sample tags in release repo --"
if ! skopeo list-tags "docker://${REPO_RELEASE}" | grep -q "${VER}"; then
  echo "WARN ${VER} string not found in ${REPO_RELEASE} tags (may still have digests)"
else
  echo "PASS found ${VER} references in release tags"
fi

# If oc available and desired image known, audit digests from payload
if command -v oc >/dev/null && oc whoami >/dev/null 2>&1; then
  IMG=$(oc get clusterversion version -o jsonpath='{.status.desired.image}' 2>/dev/null || true)
  if [[ -n "${IMG}" && "${IMG}" == *sha256* ]]; then
    echo "-- auditing digests from desired image ${IMG} --"
    missing=0
    oc adm release info "${IMG}" 2>/dev/null \
      | awk '/sha256:[0-9a-f]{64}/{print $NF}' | sort -u | head -40 \
      | while read -r d; do
          if skopeo inspect "docker://${REPO_RELEASE}@${d}" >/dev/null 2>&1; then
            echo "OK ${d}"
          else
            echo "MISSING ${d}"
            missing=1
          fi
        done
  else
    echo "INFO no desired.image digest yet — spot-check after channel/upgrade set"
    echo "     Example (4.18.52 cluster-config-api):"
    echo "     skopeo inspect docker://${REPO_RELEASE}@sha256:f015c4401dbbe321e66341d28614160ae97d5717264f6543d74384b32f01bc7f"
  fi
fi

# Known canary digest from the documented 4.18.52 incident (safe optional check)
CANARY="sha256:f015c4401dbbe321e66341d28614160ae97d5717264f6543d74384b32f01bc7f"
if [[ "${VER}" == "4.18.52" ]]; then
  echo "-- canary digest cluster-config-api --"
  if skopeo inspect "docker://${REPO_RELEASE}@${CANARY}" >/dev/null 2>&1; then
    echo "PASS canary ${CANARY}"
  else
    echo "FAIL canary ${CANARY} missing — this blocked the lab upgrade"
    exit 1
  fi
fi

echo "===== Mirror validation finished ====="
