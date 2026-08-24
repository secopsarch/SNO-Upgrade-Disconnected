#!/usr/bin/env bash
# Gate 2 — Registry / mirror trust setup and validation.
#
# This script has two modes because the fix spans two hosts:
#   extract  -> run on the WORKSTATION (has `oc` access to the cluster)
#   install  -> run on the REGISTRY HOST (has `podman`/root access)
#
# --------------------------------------------------------------------------
# Usage on the workstation:
#   ./01-registry-trust-setup.sh extract <configmap-key> [output-file]
#
#   <configmap-key> is the ConfigMap data key for your registry, e.g.
#   "registry.ocp4.example.com..8443" (dots kept, ':' -> '..'). Find it with:
#     oc get configmap registry-config -n openshift-config -o jsonpath='{.data}' | jq 'keys'
#
# Usage on the registry host (as root), after copying the extracted file over:
#   ./01-registry-trust-setup.sh install <ca-bundle.pem> <registry-host> <registry-port>
# --------------------------------------------------------------------------
set -euo pipefail

MODE="${1:-}"

usage() {
  cat <<'EOF'
Usage:
  01-registry-trust-setup.sh extract <configmap-key> [output-file]   # run on workstation
  01-registry-trust-setup.sh install <ca-bundle.pem> <host> <port>   # run on registry host (as root)
EOF
  exit 1
}

case "$MODE" in
  extract)
    KEY="${2:?configmap key required, e.g. registry.example.com..8443}"
    OUT="${3:-registry-ca-bundle.pem}"
    echo "Extracting CA bundle for key '$KEY' from openshift-config/registry-config ..."
    oc get configmap registry-config -n openshift-config \
      -o jsonpath="{.data['${KEY}']}" > "$OUT"
    COUNT=$(grep -c "BEGIN CERTIFICATE" "$OUT" || true)
    echo "Wrote $OUT ($COUNT certificate(s) found)."
    echo
    echo "Splitting and identifying each certificate in the chain:"
    rm -f /tmp/ca-split-cert*.pem
    awk '
      /BEGIN CERTIFICATE/ {n++; out="/tmp/ca-split-cert" n ".pem"}
      n {print > out}
      /END CERTIFICATE/ {close(out)}
    ' "$OUT"
    for f in /tmp/ca-split-cert*.pem; do
      [ -e "$f" ] || continue
      echo "===== $f ====="
      openssl x509 -in "$f" -noout -subject -issuer -serial -fingerprint -sha256
    done
    echo
    echo "Identify which files are the intermediate/root CA (issuer != subject of the"
    echo "leaf), copy them to the registry host, then run this script's 'install' mode there."
    ;;
  install)
    BUNDLE="${2:?ca bundle pem path required}"
    HOST="${3:?registry host required}"
    PORT="${4:?registry port required}"
    if [ "$(id -u)" -ne 0 ]; then
      echo "Run as root on the registry host." >&2
      exit 1
    fi
    ANCHOR=/etc/pki/ca-trust/source/anchors/ocp-registry-ca.crt
    echo "Installing $BUNDLE -> $ANCHOR"
    cp "$BUNDLE" "$ANCHOR"
    update-ca-trust extract
    echo "System trust store updated."

    CERTSD="/etc/containers/certs.d/${HOST}:${PORT}"
    mkdir -p "$CERTSD"
    cp "$BUNDLE" "${CERTSD}/ca.crt"
    echo "Podman/CRI trust dir populated: ${CERTSD}/ca.crt"

    echo
    echo "Validating system trust against ${HOST}:${PORT} ..."
    RESULT=$(openssl s_client -connect "${HOST}:${PORT}" -servername "${HOST}" \
      -CAfile /etc/pki/tls/certs/ca-bundle.crt </dev/null 2>/dev/null | grep "Verify return code")
    echo "$RESULT"
    if ! echo "$RESULT" | grep -q "Verify return code: 0"; then
      echo "[FAIL] System trust validation did not return 0 (ok). Check the CA chain." >&2
      exit 1
    fi

    echo
    echo "Testing podman login (you will be prompted for credentials) ..."
    podman logout "${HOST}:${PORT}" >/dev/null 2>&1 || true
    if podman login "${HOST}:${PORT}"; then
      echo "[PASS] podman login succeeded without --tls-verify=false"
    else
      echo "[FAIL] podman login still failing — do not fall back to --tls-verify=false; re-check the CA chain." >&2
      exit 1
    fi
    ;;
  *)
    usage
    ;;
esac
