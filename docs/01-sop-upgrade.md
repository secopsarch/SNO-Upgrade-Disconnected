# 01 — Full Upgrade SOP (Blind Follow)

**Title:** Disconnected SNO OpenShift z-stream upgrade (4.18.x)  
**Audience:** Platform engineer repeating this on SNO #1 recovery or SNO #2  
**Prerequisite reading:** [00-overview-constraints.md](00-overview-constraints.md)

Replace placeholders:

| Placeholder | Example |
|-------------|---------|
| `REGISTRY` | `registry.ocp4.example.com:8443` |
| `NODE` | `master01` |
| `FROM_VER` | `4.18.6` |
| `TO_VER` | `4.18.52` (use whatever `oc adm upgrade` recommends) |
| `TO_DIGEST` | digest from `oc adm upgrade` / release info |

---

# Phase 0 — Do not upgrade yet (mirror readiness)

> If you skip Phase 0, you will reproduce the lab failure: CVO starts, then sticks on `ImagePullBackOff` / `manifest unknown`.

## 0.1 Confirm kubeconfig host

Run cluster commands only from a host with valid kubeconfig (`workstation` or `utility`).

```bash
oc whoami
oc get nodes -o wide
```

## 0.2 Inventory current version and history

```bash
oc get clusterversion version -o wide
oc get clusterversion version \
  -o jsonpath='{range .status.history[*]}{.version}{" | "}{.state}{" | "}{.image}{"\n"}{end}'
oc adm upgrade
```

Record:

- Current version  
- Channel (may be empty)  
- History digest for current release  

## 0.3 Prove registry reachability from the node

```bash
oc debug node/${NODE} -- chroot /host \
  curl -I https://${REGISTRY}/v2/
```

**Pass:** HTTP `401` + `docker-distribution-api-version: registry/2.0`  
**Fail:** connection refused / TLS verify fail / timeout → fix network/TLS before anything else.

## 0.4 Fix registry-host Podman trust (if login fails)

Symptoms: `x509: certificate signed by unknown authority` on `podman login`.

### Extract CA from OpenShift ConfigMap (workstation)

```bash
oc get configmap registry-config -n openshift-config \
  -o jsonpath='{.data.registry\.ocp4\.example\.com\.\.8443}' \
  > /tmp/registry-ca-bundle.pem

grep -c "BEGIN CERTIFICATE" /tmp/registry-ca-bundle.pem
# expect 3 (leaf + intermediate + root) in this lab

awk '
/BEGIN CERTIFICATE/ {n++; out="/tmp/cert" n ".pem"}
n {print > out}
/END CERTIFICATE/ {close(out)}
' /tmp/registry-ca-bundle.pem

for f in /tmp/cert*.pem; do
  echo "===== $f ====="
  openssl x509 -in "$f" -noout -subject -issuer
done
```

Install **CA certs** (not only the leaf) on registry host:

```bash
# from workstation
scp /tmp/cert2.pem /tmp/cert3.pem root@registry:/root/

# on registry
cat /root/cert2.pem /root/cert3.pem \
  > /etc/pki/ca-trust/source/anchors/ocp-registry-ca.crt
update-ca-trust extract

mkdir -p /etc/containers/certs.d/${REGISTRY}
cp /etc/pki/ca-trust/source/anchors/ocp-registry-ca.crt \
  /etc/containers/certs.d/${REGISTRY}/ca.crt

openssl s_client -connect ${REGISTRY} \
  -servername registry.ocp4.example.com \
  -CAfile /etc/pki/tls/certs/ca-bundle.crt </dev/null 2>/dev/null \
  | grep "Verify return code"
# expect: Verify return code: 0 (ok)

podman login ${REGISTRY} -u developer
# Login Succeeded!  (TLS verify ON — do not use --tls-verify=false as the goal state)
```

## 0.5 Inventory mirror configuration (leave ICSP in place)

```bash
oc get imagecontentsourcepolicy
oc get imagedigestmirrorset
oc get imagetagmirrorset
oc get imagecontentsourcepolicy -o yaml > /tmp/icsp-backup.yaml
oc get image.config.openshift.io/cluster -o yaml > /tmp/image-config-backup.yaml
```

Expected pattern (lab):

```text
quay.io/openshift-release-dev/ocp-release      → REGISTRY/openshift/release[-images]
quay.io/openshift-release-dev/ocp-v4.0-art-dev → REGISTRY/openshift/release
registry.redhat.io/<org>                       → REGISTRY/<org>
```

Confirm node sees mirrors:

```bash
oc debug node/${NODE} -- chroot /host cat /etc/containers/registries.conf
```

## 0.6 Discover what is already in Quay

On registry:

```bash
QUAY_DATA=$(podman volume inspect quay-storage --format '{{.Mountpoint}}')
du -sh "$QUAY_DATA"
du -xhd1 "$QUAY_DATA" | sort -h

podman login ${REGISTRY} -u developer

skopeo list-tags docker://${REGISTRY}/openshift/release-images
skopeo list-tags docker://${REGISTRY}/openshift/release | grep -E "${FROM_VER}|${TO_VER}" | head
```

**Pass for upgrade to TO_VER:** release-images (or release) contains `${TO_VER}-x86_64` (or equivalent) **and** random sample digests from the payload inspect successfully.

**Lab failure signature:**

```text
Tags only for 4.18.6-x86_64*
skopeo inspect ...@sha256:f015... → manifest unknown
```

→ **Stop.** Mirror `TO_VER` completely before starting/continuing upgrade.

## 0.7 Mirror the target release (required gate)

Use a host that can reach Red Hat registries (often utility/bastion with pull secret), pushing into Quay.

### Option A — `oc adm release mirror` (classic, matches ICSP layout)

```bash
export LOCAL_REG=registry.ocp4.example.com:8443
export TO_VER=4.18.52   # replace with graph recommendation
export PULLSECRET=/path/to/pull-secret.json

# Confirm digest for TO_VER (example for 4.18.52 from lab):
# sha256:dddcb2c76b40454aac441daa388ae91c76d90b1a058adce58f3ce4e0ec957b3f

oc adm release mirror \
  --from=quay.io/openshift-release-dev/ocp-release:${TO_VER}-x86_64 \
  --to=${LOCAL_REG}/openshift/release \
  --to-release-image=${LOCAL_REG}/openshift/release-images:${TO_VER}-x86_64 \
  --pull-secret=${PULLSECRET}
```

Align `--to` / `--to-release-image` with your ICSP paths (`openshift/release` and `openshift/release-images`).

### Option B — `oc-mirror` v2 (preferred for new work; generates IDMS/ITMS)

If adopting oc-mirror v2, apply generated IDMS/ITMS **before** upgrade on a healthy cluster, and understand coexistence with existing ICSP. For an already-running stuck upgrade, prefer completing content into existing ICSP paths first.

## 0.8 Validate digests that previously failed

After mirroring:

```bash
# cluster-config-api digest from release info (example)
FAILING=sha256:f015c4401dbbe321e66341d28614160ae97d5717264f6543d74384b32f01bc7f

skopeo inspect docker://${REGISTRY}/openshift/release@${FAILING}

oc adm release info \
  quay.io/openshift-release-dev/ocp-release:${TO_VER}-x86_64 \
  --image-for=cluster-config-operator

# Spot-check several images from release info
oc adm release info quay.io/openshift-release-dev/ocp-release:${TO_VER}-x86_64 \
  | awk '/sha256:/{print $NF}' | head -20 | while read d; do
      echo "Checking $d"
      skopeo inspect docker://${REGISTRY}/openshift/release@$d >/dev/null \
        && echo OK || echo MISSING
    done
```

Node pull test:

```bash
oc debug node/${NODE} -- chroot /host \
  crictl pull ${REGISTRY}/openshift/release@${FAILING}
```

**Pass:** pull succeeds.

---

# Phase 1 — Pre-upgrade health & operators

## 1.1 Baseline health

```bash
oc get clusterversion version -o wide
oc get nodes -o wide
oc get clusteroperators
oc get mcp
oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
oc get events -A --sort-by='.lastTimestamp' | tail -50
```

**Pass criteria:**

```text
ClusterVersion Available=True Progressing=False Failing/Degraded=False
Nodes Ready
All COs Available=True Progressing=False Degraded=False
MCP UPDATED=True UPDATING=False DEGRADED=False
```

## 1.2 Operator compatibility snapshot

```bash
oc get subscription -A -o wide
oc get csv -A | grep -E 'metallb|lvms|PACKAGE'
oc get catalogsource -A
```

Record channels. Ensure catalogs resolve (CatalogSource READY).

## 1.3 etcd backup (immediately before upgrade)

```bash
oc debug --as-root node/${NODE}
# inside:
chroot /host
/usr/local/bin/cluster-backup.sh /home/core/backup
ls -lh /home/core/backup
exit; exit
```

Copy backup off-node if possible (`oc debug` + `scp` / external share).

---

# Phase 2 — Attach channel and choose target

## 2.1 Set channel

```bash
oc patch clusterversion version --type=merge \
  -p '{"spec":{"channel":"stable-4.18"}}'

oc adm upgrade
```

Wait until updates appear (RetrievedUpdates=True).

## 2.2 Select target

Use **only** a version listed under Recommended updates (or available updates you intentionally accept).

```bash
# Example — replace with listed version
export TO_VER=4.18.52
```

Re-run Phase 0.7–0.8 if not already done for this exact `TO_VER`.

---

# Phase 3 — Execute upgrade

## 3.1 Start

```bash
oc adm upgrade --to=${TO_VER}
```

## 3.2 Monitoring dashboards (4 terminals)

```bash
# T1
watch -n 5 'oc get clusterversion version'

# T2
watch -n 5 'oc get clusteroperators'

# T3
watch -n 5 'oc get nodes; echo; oc get mcp'

# T4
oc logs -n openshift-cluster-version deploy/cluster-version-operator -f
```

## 3.3 Expected SNO behavior

1. Operators Progressing=True temporarily  
2. Later: node `Ready,SchedulingDisabled`  
3. Possible API disconnect during reboot  
4. Node returns Ready; MCP Updated; version = TO_VER  

**Do not** manually cordon/drain/reboot unless documented emergency procedure and CVO/MCO are clearly wedged for reasons other than missing images.

## 3.4 If stuck early on a specific operator

```bash
oc get clusterversion version -o jsonpath='{.status.conditions[*]}{"\n"}'
oc get pods -A | grep -E 'ImagePull|ErrImage|CrashLoop|Pending'
oc describe pod -n <ns> <pod> | sed -n '/Events:/,$p'
```

If Events show `manifest unknown` on mirror → **mirror missing content** (return to Phase 0).  
CVO will retry once digests appear; usually **no need** to restart CVO.

---

# Phase 4 — Post-upgrade validation

```bash
oc get clusterversion version -o wide
oc get clusterversion version \
  -o jsonpath='{range .status.history[*]}{.version}{" | "}{.state}{" | "}{.completionTime}{"\n"}{end}'
oc get clusteroperators
oc get mcp
oc get nodes -o wide
oc get csv -n metallb-system
oc get csv -n openshift-storage
oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

Smoke:

```bash
oc get routes -A | head
# open console URL; login; check Operators → Installed
```

Optional: clear completed upgrade noise only after documenting success.

---

# Phase 5 — Handoff notes

Document:

- From → To versions and digests  
- Mirror command used and timestamp  
- ICSP names left in place  
- Any operators upgraded  
- Backup location  
- Deviations from this SOP  

Proceed to [04-second-sno-cluster.md](04-second-sno-cluster.md) for cluster #2 using the same mirror content if shared, or re-validate G3 per cluster.
