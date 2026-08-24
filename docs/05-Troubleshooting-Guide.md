# Troubleshooting Guide

## 1. Multi-layer diagnostic matrix

Use this table to decide which command to run next, based on which layer is
implicated. This is the general-purpose map; the specific scenario cluster
#1 hit is expanded in Section 3.

| Layer | Command | What it tells you |
|---|---|---|
| CVO (overall) | `oc get clusterversion` | Overall upgrade state/percentage |
| CVO (detail) | `oc describe clusterversion version` | Conditions, history, explicit error text |
| CVO logs | `oc logs -n openshift-cluster-version deploy/cluster-version-operator -f` | Which payload resource is being applied/blocked |
| ClusterOperators | `oc get co` | Per-operator health |
| Specific operator's pods | `oc get pods -n <operator-namespace>` | Workload rollout state |
| Pod detail | `oc describe pod -n <ns> <pod>` | Scheduling / image-pull / startup failure with events |
| Deployment/ReplicaSet | `oc describe deployment / rs -n <ns> <name>` | Rollout math (desired/updated/available replicas) |
| Cluster-wide events | `oc get events -A --sort-by='.lastTimestamp'` | Chronological signal across all namespaces |
| Node-specific events | `oc get events -A --field-selector involvedObject.name=<node>` | Node-scoped issues (disk, kubelet, drain) |
| Node/MCP | `oc get nodes`, `oc get mcp`, `oc describe mcp <pool>` | RHCOS/MachineConfig rollout |
| Machine Config Daemon | `oc logs -n openshift-machine-config-operator <mcd-pod>` | Drain/cordon/pivot/reboot/uncordon sequence |
| CRI (node-local) | `oc debug node/<n> -- chroot /host crictl images --digests` | What's actually cached on the node |
| CRI pull test | `oc debug node/<n> -- chroot /host crictl pull <ref>` | Direct pull attempt with full error text |
| Registry-side | `skopeo inspect docker://<mirror>/<repo>@<digest>` | Whether the mirror actually has that manifest |
| Registry logs | `podman logs <quay-container>` / `podman logs <nginx-container>` | Server-side view of the same requests |
| Network/TLS | `curl -vk https://<registry>/v2/` (from node and from registry host) | Reachability + certificate chain |
| Mirror config | `oc get imagedigestmirrorset,imagecontentsourcepolicy,imagetagmirrorset -o yaml` | Cluster-side source→mirror mapping |
| Node mirror config | `oc debug node/<n> -- chroot /host cat /etc/containers/registries.conf` | The rendered, effective mirror config on the node |
| Release payload | `oc adm release info <pullspec>` / `--image-for=<component>` | Ground truth for which digest a component maps to |

### Reading order for "the upgrade seems stuck"

```
oc get clusterversion            (is it Progressing, and what does the message say?)
      ↓
oc get co                        (which operator is Progressing/Degraded?)
      ↓
oc get pods -n <that operator's namespace>
      ↓
oc describe pod -n <ns> <pod>    (Events section — this is your "log" when a
                                   container never started)
      ↓
classify: scheduling | image pull | crashloop | readiness/liveness | other
```

## 2. Common failure classes and first response

| Symptom | Likely class | First response |
|---|---|---|
| `x509: certificate signed by unknown authority` on `podman login` | Host-level trust store missing the mirror's CA | Gate 2 procedure — extract CA from `registry-config`, install into `/etc/pki/ca-trust` and `/etc/containers/certs.d/<host>:<port>/` |
| `oc adm upgrade` says `NoChannel` / `Cannot display available updates` | Channel not set | Set `spec.channel` to the correct channel, wait for `RetrievedUpdates=True` |
| `oc adm upgrade --to=<X>` rejected / X not offered | X is not a valid edge from the current version in the current channel | Use the version(s) actually listed by `oc adm upgrade`; do not force an arbitrary version |
| CVO message: `Unable to apply <ver>: the workload <ns>/<name> has not yet successfully rolled out` | A payload Deployment can't reach minimum availability | Inspect the pod for that Deployment — almost always an image-pull or scheduling issue, see Section 3 |
| Pod stuck `Init:ImagePullBackOff` / `ErrImagePull` | Missing image, wrong mirror mapping, or registry auth failure | See Section 3 — determine which of the three with `skopeo inspect` + `crictl pull` |
| `manifest unknown` from the mirror | The mirror registry does not have that digest | The image was never mirrored for this release — mirror it (Gate 5a) |
| `unauthorized: access to the requested resource is not authorized` from `quay.io` directly | Expected in a disconnected cluster reaching the public registry — not itself the root cause | Check the **mirror** response, not the public registry response |
| Node shows `NotReady` for an extended period mid-upgrade | Reboot in progress (expected, briefly) vs. genuine boot failure | Give it the time budgeted for a normal reboot (~10–15 min); if it exceeds that, get console/BMC access to the node |
| ClusterOperator `Degraded=True` persists > 30 min | Underlying resource (secret, cert, PVC, quota) blocking the operator's controller | `oc describe co <name>`, then follow its `relatedObjects` |
| Operator (MetalLB/LVM) CSV stuck `Pending`/`Installing` after platform upgrade | Catalog/bundle images not mirrored for the new index, or no compatible channel | Re-check Gate 6; mirror the updated catalog if needed |
| `skopeo list-tags` shows old tags only (e.g. only `4.18.6-x86_64`) | Mirror was never refreshed for the new target version | This is the cluster #1 root cause — proceed to Gate 5a mirroring |

## 3. Deep dive — the exact cluster #1 scenario: `ImagePullBackOff` on `openshift-config-operator` during CVO rollout

### Symptom chain (in the order it was observed)

1. `oc get clusterversion version` →
   `Working towards 4.18.52: 69 of 906 done (7% complete), waiting on config-operator`
2. A few minutes later:
   `Unable to apply 4.18.52: the workload openshift-config-operator/openshift-config-operator has not yet successfully rolled out`
3. `oc get pods -n openshift-config-operator` →
   `openshift-config-operator-<hash> 0/1 Init:ImagePullBackOff`
4. `oc describe pod -n openshift-config-operator <pod>` → Events:
   ```
   Failed to pull image "quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:f015c440...":
   initializing source docker://...: (Mirrors also failed:
   [registry.<mirror>:8443/openshift/release@sha256:f015c440...:
   reading manifest sha256:f015c440... in registry.<mirror>:8443/openshift/release:
   manifest unknown]):
   ...: unauthorized: access to the requested resource is not authorized
   ```

### Diagnostic sequence used (reusable verbatim on cluster #2)

```bash
# 1. Confirm the exact failing digest and which init container needs it
oc get pod -n openshift-config-operator <pod> \
  -o jsonpath='{range .spec.initContainers[*]}{.name}{" => "}{.image}{"\n"}{end}'

# 2. Confirm it is genuinely absent from the mirror, not a fluke
skopeo inspect docker://<mirror-host>:<port>/openshift/release@sha256:<digest>
#   -> "manifest unknown"  means: not in the mirror at all

# 3. Confirm the node's rendered mirror mapping is what you expect
oc debug node/<node> -- chroot /host cat /etc/containers/registries.conf

# 4. Confirm the node genuinely cannot pull it either way
oc debug node/<node> -- chroot /host \
  crictl pull quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:<digest>
oc debug node/<node> -- chroot /host \
  crictl pull <mirror-host>:<port>/openshift/release@sha256:<digest>

# 5. Identify which release component that digest belongs to (for the record)
oc adm release info <target-release-pullspec> | grep -i config
oc adm release info <target-release-pullspec> --image-for=cluster-config-operator
```

### Root cause

The mirror registry had only ever been populated with the **4.18.6** release
content (confirmed via `skopeo list-tags` returning a single
`4.18.6-x86_64` tag on `openshift/release-images`). The 4.18.52 payload
requires dozens of new/changed component digests (in this case,
`cluster-config-api`) that simply do not exist yet in the local Quay. This is
**not** a certificate problem (TLS/auth to the mirror already worked), not a
DNS/network problem (the mirror answered with a valid, well-formed `401`/
`manifest unknown`), and not an OpenShift bug — it is a **stale mirror**.

### Fix

1. Read the exact digest the CVO is currently applying:
   `oc get clusterversion version -o jsonpath='{.status.desired.image}'`.
2. Build/obtain an `ImageSetConfiguration` for that exact release (see
   `manifests/imagesetconfig-release.yaml`), pointed at `channels: - name:
   stable-4.18 minVersion: <target> maxVersion: <target>` (or a small range
   spanning the hop) so `oc-mirror` fetches the full digest closure for that
   payload plus its referenced component images.
3. Run `scripts/04-mirror-missing-release-images.sh` to execute the mirror.
4. Do **not** manually retag or fabricate an image at that digest — the
   digest is a cryptographic hash of the real content; only the genuine
   image will satisfy it.
5. Once mirrored, the kubelet's existing backoff loop will succeed on its
   next retry, or delete the stuck pod once to force an immediate retry.
   The CVO will then resume the payload apply from where it left off — you
   do **not** need to restart the upgrade from scratch.

### What NOT to do (all confirmed anti-patterns from this scenario)

- Do not repeatedly `oc delete pod` hoping the image magically appears —
  fix the mirror first.
- Do not cordon/drain the node manually — this isn't a scheduling problem
  and the CVO/MCO own that lifecycle.
- Do not edit `/etc/containers/registries.conf` on the node by hand — it is
  machine-config-managed and will be reconciled back (or drift silently).
- Do not restart the CVO deployment or edit `ClusterVersion.status` — it is
  correctly waiting; it needs the environment fixed, not itself fixed.
- Do not add `--tls-verify=false` to work around trust issues — fix the
  actual CA trust (Gate 2) instead; TLS bypass will mask the next real
  problem too.
- Do not assume `crictl images` showing many `ocp-v4.0-art-dev` images means
  the required digest is present — release payloads pin exact digests;
  "similar" images are not equivalent.

## 4. Escalation-free decision tree

```
Upgrade not progressing?
├─ Is `oc get clusterversion` Progressing=True with an increasing counter?
│   └─ YES → normal, keep watching (Section "Recognize a genuine stall")
├─ Is the message "Unable to apply <ver>: workload <ns>/<name> not rolled out"?
│   └─ YES → oc get pods -n <ns>; classify pod state
│       ├─ Init:ImagePullBackOff / ErrImagePull → Section 3 flow
│       ├─ CrashLoopBackOff → oc logs <pod> --previous; check config/secret
│       ├─ Pending (unscheduled) → oc describe pod; check taints/resources
│       └─ Running but NotReady → check readiness probe / dependent service
├─ Is a ClusterOperator Degraded=True?
│   └─ YES → oc describe co <name>; walk relatedObjects
├─ Is a node NotReady beyond a normal reboot window?
│   └─ YES → console/BMC access; check kubelet/crio service status on node
└─ None of the above → capture `oc adm must-gather` and the CVO log window
    around the stall before making any further changes
```
