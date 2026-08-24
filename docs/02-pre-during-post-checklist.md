# 02 — Pre / During / Post Upgrade Checklist (Categorical)

Use this as a printable gate checklist. Mark each item Pass / Fail / N/A. **Do not proceed past a Fail in Pre.**

Cluster name: _______________ Date: _______________ Operator: _______________

---

## A. PRE-UPGRADE

### A1. Access & tooling

| # | Check | Command / evidence | Pass? |
|---|--------|--------------------|-------|
| A1.1 | kubeconfig works | `oc whoami` | ☐ |
| A1.2 | Correct cluster context | `oc config current-context`; node IPs match inventory | ☐ |
| A1.3 | `oc` / `skopeo` / `podman` available on right hosts | versions recorded | ☐ |
| A1.4 | Pull secret available on **mirror host** | file path known | ☐ |

### A2. Cluster health baseline

| # | Check | Expected | Pass? |
|---|--------|----------|-------|
| A2.1 | ClusterVersion | Available=True, Progressing=False, Failing=False | ☐ |
| A2.2 | Nodes | Ready; SNO shows master+worker roles | ☐ |
| A2.3 | ClusterOperators | all Available=True, Progressing=False, Degraded=False | ☐ |
| A2.4 | MCP | UPDATED=True, UPDATING=False, DEGRADED=False | ☐ |
| A2.5 | Non-running pods | only expected Jobs/Completed; no CrashLoop | ☐ |
| A2.6 | PVCs / storage | LVMS healthy if used | ☐ |
| A2.7 | Recent adverse events | reviewed last 50 events | ☐ |

### A3. Disconnected registry / trust

| # | Check | Expected | Pass? |
|---|--------|----------|-------|
| A3.1 | ConfigMap `registry-config` exists | `oc get cm -n openshift-config registry-config` | ☐ |
| A3.2 | Key name | `registry.<host>..<port>` (double-dot) | ☐ |
| A3.3 | Node → registry `/v2/` | HTTP 401, TLS verify OK | ☐ |
| A3.4 | Registry host Podman login | Succeeded without `--tls-verify=false` | ☐ |
| A3.5 | certs.d present | `/etc/containers/certs.d/<registry>/ca.crt` | ☐ |
| A3.6 | Quay containers healthy | `podman ps` shows quay/nginx up | ☐ |
| A3.7 | Disk space for mirror | enough free space for full release (~tens of GB) | ☐ |

### A4. Mirror policy (API resources)

| # | Check | Expected | Pass? |
|---|--------|----------|-------|
| A4.1 | ICSP listed | `image-policy`, `release-*`, `operator-*` (names may vary) | ☐ |
| A4.2 | IDMS/ITMS | none OR intentional; do not conflict mid-flight | ☐ |
| A4.3 | registries.conf mirrors | art-dev → `.../openshift/release`; release → release[-images] | ☐ |
| A4.4 | ICSP YAML backed up | saved under change ticket | ☐ |
| A4.5 | image.config additionalTrustedCA | points at registry-config | ☐ |

### A5. Mirror **content** for TARGET (critical)

| # | Check | Expected | Pass? |
|---|--------|----------|-------|
| A5.1 | Target version chosen from graph | listed by `oc adm upgrade` | ☐ |
| A5.2 | release-images tag for TO_VER | `skopeo list-tags` shows it | ☐ |
| A5.3 | release repo has TO_VER component tags | grep TO_VER | ☐ |
| A5.4 | `cluster-config-api` digest inspect | `skopeo inspect ...@sha256:...` OK | ☐ |
| A5.5 | `cluster-config-operator` digest inspect | OK | ☐ |
| A5.6 | Spot-check ≥20 payload digests | all OK or documented exceptions | ☐ |
| A5.7 | Node `crictl pull` of failing digest | succeeds | ☐ |

### A6. Operators

| # | Check | Expected | Pass? |
|---|--------|----------|-------|
| A6.1 | Subscriptions | MetalLB + LVMS present; channels recorded | ☐ |
| A6.2 | CSVs | Succeeded | ☐ |
| A6.3 | CatalogSource | READY / pods running | ☐ |
| A6.4 | Operator images mirrored if disconnected | catalogs + related images available | ☐ |

### A7. Backup & change control

| # | Check | Expected | Pass? |
|---|--------|----------|-------|
| A7.1 | etcd backup taken | `cluster-backup.sh` completed | ☐ |
| A7.2 | Backup copied off-node | path documented | ☐ |
| A7.3 | Maintenance window | stakeholders notified (SNO downtime) | ☐ |
| A7.4 | Rollback expectations | SNO restore limitations understood | ☐ |

**PRE GATE:** All A2, A3, A5 critical rows Pass → proceed.

---

## B. DURING UPGRADE

### B1. Initiation

| # | Check | Notes | Pass? |
|---|--------|-------|-------|
| B1.1 | Channel set | `stable-4.18` (or approved) | ☐ |
| B1.2 | Graph retrieved | Recommended updates visible | ☐ |
| B1.3 | `oc adm upgrade --to=TO_VER` issued | version matches graph | ☐ |
| B1.4 | History Partial for TO_VER | expected | ☐ |

### B2. Live monitoring

| # | Watch | Healthy signal | Alert if |
|---|-------|----------------|----------|
| B2.1 | `oc get clusterversion` | Progressing=True; % increasing over time | stuck same % >30–60m without CO activity |
| B2.2 | `oc get co` | temporary Progressing | Degraded=True sustained |
| B2.3 | `oc get mcp` | later Updating=True | Degraded=True |
| B2.4 | `oc get nodes` | SchedulingDisabled then reboot | NotReady forever after reboot window |
| B2.5 | CVO logs | applying resources | repeated same WorkloadNotAvailable + ImagePull |
| B2.6 | Registry logs | GET manifests 200 | flood of 404 manifest unknown |

### B3. Forbidden actions during healthy upgrade

| # | Do NOT | Why |
|---|--------|-----|
| B3.1 | Manual cordon/drain | Interferes with MCO on SNO |
| B3.2 | Delete CVO / force status edits | Corrupts upgrade state |
| B3.3 | Edit operator Deployment images | CVO owns them |
| B3.4 | Hand-edit registries.conf | Drift; overwritten |
| B3.5 | Panic on API loss during reboot | Expected on SNO |

### B4. If ImagePullBackOff appears

| Step | Action | Done? |
|------|--------|-------|
| 1 | `oc describe pod` → Events | ☐ |
| 2 | Classify: manifest unknown vs unauthorized vs TLS | ☐ |
| 3 | If manifest unknown → mirror missing digest; mirror now | ☐ |
| 4 | Re-test `skopeo inspect` + `crictl pull` | ☐ |
| 5 | Wait for CVO retry (do not thrash delete pods) | ☐ |
| 6 | Only if mapping wrong → correct ICSP/IDMS on **healthy** path | ☐ |

---

## C. POST-UPGRADE

### C1. Version & operators

| # | Check | Expected | Pass? |
|---|--------|----------|-------|
| C1.1 | Cluster version | equals TO_VER | ☐ |
| C1.2 | Available / Progressing / Failing | True / False / False | ☐ |
| C1.3 | History Completed for TO_VER | completionTime set | ☐ |
| C1.4 | All ClusterOperators | healthy | ☐ |
| C1.5 | MCP | Updated, not Updating, not Degraded | ☐ |
| C1.6 | Node | Ready; kubelet version consistent | ☐ |

### C2. Workloads & operators

| # | Check | Expected | Pass? |
|---|--------|----------|-------|
| C2.1 | MetalLB CSV | Succeeded | ☐ |
| C2.2 | LVMS CSV | Succeeded | ☐ |
| C2.3 | Abnormal pods | none unexpected | ☐ |
| C2.4 | Console login | works | ☐ |
| C2.5 | Sample route / app | works | ☐ |

### C3. Registry & config hygiene

| # | Check | Expected | Pass? |
|---|--------|----------|-------|
| C3.1 | ICSP still present | unchanged unless planned | ☐ |
| C3.2 | registry-config intact | CA still trusted | ☐ |
| C3.3 | No leftover debug pods | cleaned | ☐ |
| C3.4 | Mirror retention | TO_VER content retained for rollback window | ☐ |

### C4. Documentation

| # | Item | Done? |
|---|------|-------|
| C4.1 | Change record updated (from/to, digests, duration) | ☐ |
| C4.2 | Issues & remediations logged | ☐ |
| C4.3 | Backup retention confirmed | ☐ |
| C4.4 | Lessons applied to SNO #2 checklist | ☐ |

**POST GATE:** C1 all Pass + C2 smoke Pass → upgrade closed.

---

## Quick command block (copy/paste)

```bash
echo "===== PRE/POST SNAPSHOT ====="
oc get clusterversion version -o wide
oc adm upgrade
oc get nodes -o wide
oc get clusteroperators
oc get mcp
oc get imagecontentsourcepolicy
oc get imagedigestmirrorset
oc get subscription -A -o wide
oc get catalogsource -A
oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```
