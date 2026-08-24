#!/usr/bin/env bash
# Gate 3 (mirror config inventory) + Gate 5 (digest-level content validation)
# + registry storage headroom check.
#
# Usage:
#   ./02-inventory-mirror-content.sh inventory
#       Run on the workstation. Dumps ICSP/IDMS/ITMS and the effective
#       node-level registries.conf for review.
#
#   ./02-inventory-mirror-content.sh validate <target-release-pullspec> [node-name]
#       Run on the workstation. Enumerates every component digest in the
#       target release payload and checks whether it resolves through the
#       mirror as the node would see it. THIS IS THE CHECK THAT WOULD HAVE
#       CAUGHT THE CLUSTER #1 FAILURE BEFORE THE UPGRADE STARTED.
#
#   ./02-inventory-mirror-content.sh storage
#       Run on the REGISTRY HOST. Reports Quay storage volume usage and
#       free space.
set -uo pipefail

MODE="${1:-}"

case "$MODE" in
  inventory)
    echo "### ImageContentSourcePolicy ###"
    oc get imagecontentsourcepolicy -o yaml 2>&1
    echo
    echo "### ImageDigestMirrorSet ###"
    oc get imagedigestmirrorset -o yaml 2>&1
    echo
    echo "### ImageTagMirrorSet ###"
    oc get imagetagmirrorset -o yaml 2>&1
    echo
    echo "### image.config.openshift.io/cluster ###"
    oc get image.config.openshift.io/cluster -o yaml 2>&1
    echo
    NODE_NAME=$(oc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$NODE_NAME" ]; then
      echo "### Effective node registries.conf ($NODE_NAME) ###"
      oc debug node/"$NODE_NAME" -- chroot /host cat /etc/containers/registries.conf 2>&1
    fi
    ;;

  validate)
    RELEASE="${2:?target release pullspec or digest required}"
    NODE_NAME="${3:-$(oc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)}"
    echo "Enumerating component images for release: $RELEASE"
    echo "(this can take a minute — oc adm release info reads the full payload)"
    echo

    TMP_IMAGES=$(mktemp)
    # Format: "<name> <pullspec>"
    oc adm release info "$RELEASE" -o jsonpath='{range .references.spec.tags[*]}{.name} {.from.name}{"\n"}{end}' \
      > "$TMP_IMAGES" 2>/tmp/release-info.err || {
        echo "[FAIL] 'oc adm release info' failed. Falling back to text-mode parsing." >&2
        oc adm release info "$RELEASE" > /tmp/release-info.txt 2>>/tmp/release-info.err
        cat /tmp/release-info.txt
      }

    TOTAL=0
    OK=0
    MISSING=0
    MISSING_LIST=()

    while read -r name pullspec; do
      [ -z "$pullspec" ] && continue
      TOTAL=$((TOTAL+1))
      # Ask the node itself to resolve the pull via its configured mirrors —
      # this is the most faithful test because it uses the exact same
      # registries.conf the kubelet uses.
      if [ -n "$NODE_NAME" ]; then
        if oc debug node/"$NODE_NAME" -- chroot /host crictl pull "$pullspec" >/tmp/pull-"$name".log 2>&1; then
          OK=$((OK+1))
        else
          MISSING=$((MISSING+1))
          MISSING_LIST+=("$name -> $pullspec")
        fi
      fi
    done < "$TMP_IMAGES"

    echo
    echo "### Digest resolution summary ###"
    echo "Total components checked: $TOTAL"
    echo "Resolved via mirror:      $OK"
    echo "MISSING from mirror:      $MISSING"
    if [ "$MISSING" -gt 0 ]; then
      echo
      echo "The following component images are NOT available through the mirror."
      echo "This is exactly the condition that stalled cluster #1. Proceed to"
      echo "Gate 5a / scripts/04-mirror-missing-release-images.sh before starting"
      echo "the upgrade."
      printf '  - %s\n' "${MISSING_LIST[@]}"
      rm -f "$TMP_IMAGES"
      exit 1
    fi
    rm -f "$TMP_IMAGES"
    echo "[PASS] All component images for $RELEASE resolve through the mirror."
    ;;

  storage)
    echo "Run this on the REGISTRY HOST."
    QUAY_DATA=$(podman volume inspect quay-storage --format '{{.Mountpoint}}' 2>/dev/null || true)
    if [ -z "$QUAY_DATA" ]; then
      echo "Could not find 'quay-storage' podman volume; adjust this script if your"
      echo "registry uses a different volume/deployment name."
      exit 1
    fi
    echo "Quay storage: $QUAY_DATA"
    echo
    echo "=== Usage ==="
    du -sh "$QUAY_DATA"
    echo
    echo "=== Filesystem free space ==="
    df -h "$QUAY_DATA"
    ;;

  *)
    echo "Usage: $0 {inventory|validate <release-pullspec> [node]|storage}" >&2
    exit 1
    ;;
esac
