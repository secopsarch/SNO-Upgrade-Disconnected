#!/usr/bin/env bash
# Reproduces the exact diagnostic sequence from
# docs/05-Troubleshooting-Guide.md Section 3, for a given failing digest.
#
# Usage: ./07-diagnose-image-pull-failure.sh <namespace> <pod> <digest-or-pullspec> [node]
#
# Example:
#   ./07-diagnose-image-pull-failure.sh openshift-config-operator \
#     openshift-config-operator-5467c84d4d-2qs2g \
#     quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:f015c440... \
#     master01
set -uo pipefail

NS="${1:?namespace required}"
POD="${2:?pod name required}"
IMAGE="${3:?image pullspec or digest reference required}"
NODE="${4:-$(oc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)}"

echo "### 1. Pod detail / events ###"
oc describe pod -n "$NS" "$POD" | sed -n '/Events:/,$p'

echo
echo "### 2. Init/container image references on the pod ###"
oc get pod -n "$NS" "$POD" -o jsonpath='{range .spec.initContainers[*]}{.name}{" => "}{.image}{"\n"}{end}'
oc get pod -n "$NS" "$POD" -o jsonpath='{range .spec.containers[*]}{.name}{" => "}{.image}{"\n"}{end}'

echo
echo "### 3. Node-rendered mirror configuration ($NODE) ###"
oc debug node/"$NODE" -- chroot /host cat /etc/containers/registries.conf 2>&1

echo
echo "### 4. Direct pull attempt from the node (source reference) ###"
oc debug node/"$NODE" -- chroot /host crictl pull "$IMAGE" 2>&1 || true

echo
echo "### 5. Skopeo inspect against the mirror directly (run on registry host if this fails from here) ###"
skopeo inspect "docker://${IMAGE}" 2>&1 || true

echo
echo "### Interpretation ###"
echo "- 'manifest unknown' from the mirror  => image was never mirrored for this"
echo "  release. Proceed to Gate 5a (scripts/04-mirror-missing-release-images.sh)."
echo "- 'unauthorized' from the public registry (quay.io/registry.redhat.io)"
echo "  => expected in a disconnected cluster; NOT itself the root cause."
echo "- If BOTH succeed here but the pod still fails, re-check for a typo in the"
echo "  digest, or a propagation delay in the mirror's own indexing."
