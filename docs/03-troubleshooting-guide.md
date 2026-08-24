# 03 — Troubleshooting Guide (Disconnected SNO Upgrade)

## 1. Troubleshooting philosophy

Work **outside-in / top-down**:

```text
CVO status → failing ClusterOperator → Deployment/Pod Events → image pull error
    → mirror path (ICSP) → registry content (skopeo) → network/TLS/auth
```

Never start by rebooting the SNO node or deleting random pods.

---

## 2. Layered matrix

| Layer | Commands | Tells you |
|-------|----------|-----------|
| CVO | `oc get clusterversion version -o wide` | Overall upgrade progress |
| CVO detail | `oc get clusterversion version -o yaml` | conditions, history, desired image |
| CVO logs | `oc logs -n openshift-cluster-version deploy/cluster-version-operator --tail=200` | which payload resource failed |
| Operators | `oc get clusteroperators` | which CO blocked |
| Workload | `oc get pods -n <ns>`; `oc describe pod` | ImagePull / CrashLoop |
| Events | `oc get events -n <ns> --sort-by=.lastTimestamp` | authoritative for pull failures |
| Node | `oc get nodes`; `oc describe node` | Ready / SchedulingDisabled |
| MCO | `oc get mcp`; MCD logs | drain/pivot/reboot |
| Mirror API | `oc get icsp,idms,itms -o yaml` | rewrite rules |
| Node registries | `oc debug node/... -- chroot /host cat /etc/containers/registries.conf` | applied mirrors |
| Registry | `skopeo inspect`; `podman logs` | manifest present? |
| TLS | `curl -vk https://REGISTRY/v2/` | trust / reachability |

---

## 3. Decode common CVO messages

| Message | Meaning | Action |
|---------|---------|--------|
| `NoChannel` | channel unset | `oc patch` channel; wait for graph |
| `Working towards X: N of M done, waiting on <op>` | normal sequencing | monitor that operator |
| `Unable to apply X: workload ... has not yet successfully rolled out` | deployment not Available | describe pods |
| `ProgressDeadlineExceeded` / `MinimumReplicasUnavailable` | replicas never ready | almost always image/config |
| `PayloadLoaded` + `Partial` history | upgrade accepted mid-flight | continue; fix blockers |
| `%` stuck / Done count drops slightly | reconciliation bookkeeping | not necessarily rollback |

---

## 4. ImagePullBackOff decision tree

```text
ImagePullBackOff / ErrImagePull
        │
        ▼
oc describe pod → Events
        │
        ├── TLS / x509 unknown authority
        │     → fix additionalTrustedCA / certs.d / CA bundle
        │
        ├── dial tcp / no such host / timeout
        │     → DNS, firewall, registry down
        │
        ├── unauthorized (to quay.io) AND mirror manifest unknown
        │     → classic disconnected gap: MIRROR MISSING DIGEST
        │
        ├── unauthorized (to local registry)
        │     → pull secret / Quay robot perms for node
        │
        ├── manifest unknown (mirror only)
        │     → content missing or wrong repo mapping
        │
        └── success on crictl pull but pod still fails
              → SA pull secrets, node-specific, transient — recheck events
```

### Lab root cause (exact)

```text
Pulling: quay.io/.../ocp-v4.0-art-dev@sha256:f015c4401dbbe...
Mirror:  REGISTRY/openshift/release@sha256:f015... → manifest unknown
Upstream quay.io → unauthorized
Init container openshift-api never starts → oc logs empty
CVO waits on openshift-config-operator (~65/906)
```

`f015...` = `cluster-config-api` image in 4.18.52 payload.

---

## 5. Playbooks

### Playbook P1 — Stuck on config-operator ImagePullBackOff

1. Identify pod and events:

```bash
oc get pods -n openshift-config-operator
POD=$(oc get pods -n openshift-config-operator -o name | head -1)
oc describe -n openshift-config-operator $POD | sed -n '/Events:/,$p'
oc get -n openshift-config-operator $POD \
  -o jsonpath='{range .spec.initContainers[*]}{.name}{" => "}{.image}{"\n"}{end}'
```

2. Confirm digest missing in mirror:

```bash
DIGEST=sha256:f015c4401dbbe321e66341d28614160ae97d5717264f6543d74384b32f01bc7f
skopeo inspect docker://registry.ocp4.example.com:8443/openshift/release@${DIGEST}
```

3. Mirror full target release into ICSP paths (see SOP Phase 0.7).

4. Re-test:

```bash
skopeo inspect docker://registry.ocp4.example.com:8443/openshift/release@${DIGEST}
oc debug node/master01 -- chroot /host \
  crictl pull registry.ocp4.example.com:8443/openshift/release@${DIGEST}
```

5. Wait for kubelet retry / CVO sync (minutes). Optionally delete **only** the stuck pod **after** content is fixed to speed retry:

```bash
oc delete pod -n openshift-config-operator --field-selector=status.phase=Pending
```

### Playbook P2 — Podman login x509 on registry host

1. Confirm OpenShift already trusts registry (`curl` from node → 401).  
2. Export CA from `registry-config` ConfigMap.  
3. Install intermediate+root into trust + `certs.d`.  
4. `update-ca-trust extract`; retest login **with TLS verify**.

### Playbook P3 — Channel set but no recommended updates

```bash
oc get clusterversion version \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}'
```

- Still `NoChannel` → patch failed  
- `RetrievedUpdates=False` with network error → upstream Cincinnati unreachable; for disconnected, use local graph / `--to-image` with mirrored release  
- Empty recommendations → check channel name (`stable-4.18`)

### Playbook P4 — Node NotReady after reboot longer than expected

1. Console/IPMI/iDRAC: is node booting?  
2. From another host: API VIP/IP listening?  
3. When API returns:

```bash
oc get nodes; oc get mcp; oc get co machine-config -o yaml
oc logs -n openshift-machine-config-operator -l k8s-app=machine-config-daemon --tail=200
```

4. Distinguish first boot after OS pivot (can be slow) vs bootloop (MCD pivot errors).

### Playbook P5 — `oc logs` returns NotFound / empty during ImagePull

- Verify **exact** pod name (ReplicaSet hash typos are common).  
- If init never started, logs will be empty — use Events.  
- Do not chase log paths for ImagePullBackOff.

### Playbook P6 — Wrong tool host

`oc` on registry host without kubeconfig fails — expected. Use workstation/utility.

---

## 6. Validation snippets to create on the fly

### Extract desired release & component digests

```bash
IMG=$(oc get clusterversion version -o jsonpath='{.status.desired.image}')
echo "$IMG"
oc adm release info "$IMG" --image-for=cluster-config-operator
oc adm release info "$IMG" | grep -iE 'cluster-config|machine-config|cluster-version'
```

### Bulk mirror presence check

```bash
REG=registry.ocp4.example.com:8443
IMG=$(oc get clusterversion version -o jsonpath='{.status.desired.image}')
oc adm release info "$IMG" | awk '/sha256:[0-9a-f]{64}/{print $NF}' | sort -u > /tmp/digests.txt
while read d; do
  skopeo inspect docker://$REG/openshift/release@$d >/dev/null 2>&1 \
    && echo "OK $d" || echo "MISSING $d"
done < /tmp/digests.txt | tee /tmp/mirror-audit.txt
grep MISSING /tmp/mirror-audit.txt | wc -l
```

### Four-terminal dashboard

```bash
watch -n 5 'oc get clusterversion version'
watch -n 5 'oc get clusteroperators | awk "NR==1 || \$3==\"False\" || \$4==\"True\" || \$5==\"True\""'
watch -n 5 'oc get nodes; echo; oc get mcp'
oc logs -n openshift-cluster-version deploy/cluster-version-operator -f
```

---

## 7. What “good” looks like after fix

```text
skopeo inspect mirror@digest     → config + layers
crictl pull mirror@digest        → success
config-operator pod              → Running 1/1
CVO                              → progress beyond 65/906
Eventually                       → version TO_VER Completed
```
