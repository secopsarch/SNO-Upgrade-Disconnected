#!/usr/bin/env bash
# Gate 5a — Mirror the target release (and/or operator catalog) using
# oc-mirror v2. Run from the workstation/registry host that can reach the
# local mirror registry (and, for mirror-to-mirror mode, the upstream
# source registries too).
#
# Usage:
#   ./04-mirror-missing-release-images.sh release <mirror-host:port> [imageset-config]
#   ./04-mirror-missing-release-images.sh operators <mirror-host:port> [imageset-config]
#   ./04-mirror-missing-release-images.sh apply-generated <workspace-dir>
#
# "release"/"operators" run a mirror-to-mirror pass using the given
# ImageSetConfiguration (defaults to manifests/imagesetconfig-release.yaml
# or manifests/imagesetconfig-operators.yaml relative to the repo root).
#
# "apply-generated" reviews and (after confirmation) applies the
# IDMS/ITMS/CatalogSource manifests oc-mirror generated under
# <workspace-dir>/working-dir/cluster-resources/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"

case "$MODE" in
  release)
    MIRROR="${2:?mirror host:port required, e.g. registry.example.com:8443}"
    CFG="${3:-$REPO_ROOT/manifests/imagesetconfig-release.yaml}"
    WORKSPACE="${WORKSPACE:-/var/oc-mirror/release}"
    mkdir -p "$WORKSPACE"
    echo "Using ImageSetConfiguration: $CFG"
    echo "Mirroring to: docker://$MIRROR"
    echo "Workspace: $WORKSPACE"
    echo
    grep -q '<CURRENT_VERSION>\|<TARGET_VERSION>' "$CFG" && {
      echo "[FAIL] $CFG still has placeholder values. Fill in minVersion/maxVersion" >&2
      echo "       from Gate 4's recommended target before running this." >&2
      exit 1
    }
    oc mirror -c "$CFG" --workspace "file://$WORKSPACE" "docker://$MIRROR" --v2
    ;;

  operators)
    MIRROR="${2:?mirror host:port required, e.g. registry.example.com:8443}"
    CFG="${3:-$REPO_ROOT/manifests/imagesetconfig-operators.yaml}"
    WORKSPACE="${WORKSPACE:-/var/oc-mirror/operators}"
    mkdir -p "$WORKSPACE"
    echo "Using ImageSetConfiguration: $CFG"
    echo "Mirroring to: docker://$MIRROR"
    echo "Workspace: $WORKSPACE"
    echo
    grep -q '<CATALOG_INDEX_IMAGE>' "$CFG" && {
      echo "[FAIL] $CFG still has placeholder <CATALOG_INDEX_IMAGE>. Fill it in from" >&2
      echo "       'oc get catalogsource -A' before running this." >&2
      exit 1
    }
    oc mirror -c "$CFG" --workspace "file://$WORKSPACE" "docker://$MIRROR" --v2
    ;;

  apply-generated)
    WORKSPACE="${2:?workspace dir required}"
    RES_DIR="$WORKSPACE/working-dir/cluster-resources"
    if [ ! -d "$RES_DIR" ]; then
      echo "[FAIL] $RES_DIR not found. Did the mirror run complete?" >&2
      exit 1
    fi
    echo "Generated cluster resources in $RES_DIR:"
    ls -la "$RES_DIR"
    echo
    echo "--- Diff against currently-applied mirror config ---"
    for f in "$RES_DIR"/*.yaml; do
      echo "=== $f ==="
      cat "$f"
      echo
    done
    read -r -p "Apply ALL of the above to the cluster now? [y/N] " CONFIRM
    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
      oc apply -f "$RES_DIR"
    else
      echo "Skipped. Review, edit, and 'oc apply -f $RES_DIR' manually when ready."
    fi
    ;;

  *)
    echo "Usage: $0 {release|operators} <mirror-host:port> [imageset-config]" >&2
    echo "       $0 apply-generated <workspace-dir>" >&2
    exit 1
    ;;
esac
