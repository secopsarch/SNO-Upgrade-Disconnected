# 00 — Overview: Constraints, Knowns, Unknowns, Architecture

## 1. Scenario summary

| Item | Value (reference lab) |
|------|------------------------|
| Topology | Single Node OpenShift (SNO) |
| Starting version | OpenShift **4.18.6** |
| Target (recommended in graph) | **4.18.52** (4.18.53 was *not* listed) |
| Release digest (4.18.52) | `quay.io/openshift-release-dev/ocp-release@sha256:dddcb2c76b40454aac441daa388ae91c76d90b1a058adce58f3ce4e0ec957b3f` |
| Installed digest (4.18.6) | `quay.io/openshift-release-dev/ocp-release@sha256:61fdad894f035a8b192647c224faf565279518255bdbf60a91db4ee0479adaa6` |
| Mirror registry | `registry.ocp4.example.com:8443` (nginx → Quay 3.8.12) |
| Mirror storage | ~152 GB Quay blob store (`quay-storage`) |
| Mirror mechanism | Legacy **ImageContentSourcePolicy (ICSP)** — no IDMS/ITMS |
| Trusted CA ConfigMap | `openshift-config/registry-config` key `registry.ocp4.example.com..8443` |
| OLM operators of interest | MetalLB (`stable`), LVMS (`stable-4.18`) via `gls-catalog-cs` |
| Node | `master01` — roles: control-plane, master, worker |

---

## 2. Constraints (hard rules)

### Network / disconnected

1. Cluster nodes **must not depend** on pulling from `quay.io` or `registry.redhat.io` during upgrade (typically `unauthorized` without pull secret / egress).
2. All release and operator images for the **target** version must exist in the local mirror **before** or **immediately when** CVO starts applying that payload.
3. Digest-only pulls: ICSP uses `pull-from-mirror = "digest-only"`. Tags alone do not satisfy a digest request.

### SNO-specific

4. Do **not** manually `oc adm cordon` / `drain` the single node during upgrade — MCO does this.
5. Temporary API/console loss during RHCOS reboot is **expected**.
6. etcd backup is still recommended; restore options on SNO are limited — treat backup as last-resort evidence, not a full HA recovery plan.

### Configuration drift

7. Do **not** hand-edit `/etc/containers/registries.conf` on the node (managed from ICSP/IDMS).
8. Do **not** manually edit CVO-owned Deployments (e.g. `openshift-config-operator`) image fields.
9. Do **not** delete ImagePullBackOff pods as the first fix — fix the mirror content.
10. Do **not** migrate ICSP → IDMS mid-upgrade unless planned and tested; existing ICSPs remain supported on 4.18.
11. Preserve ConfigMap key naming: `registry.ocp4.example.com..8443` (double-dot for port).

### Process

12. Do not invent a target version (e.g. 4.18.53) unless `oc adm upgrade` lists it.
13. Set channel → wait for graph → upgrade to recommended target.
14. Mirror content validation is a **gate** before starting upgrade on the second cluster.

---

## 3. Knowns (proven in conversation)

| Known | Evidence |
|-------|----------|
| Cluster healthy at 4.18.6 | All COs Available; MCP Updated; node Ready |
| Channel was empty (`NoChannel`) | `RetrievedUpdates=False` until patched to `stable-4.18` |
| `status.currentImage` empty is OK | History + `ReleaseAccepted` / PayloadLoaded hold the digest |
| Registry TLS from node works | `curl -I https://registry.../v2/` → **HTTP 401** |
| Podman on registry host initially lacked CA | Fixed via anchors + `/etc/containers/certs.d/.../ca.crt` |
| Mirror mapping correct | `ocp-v4.0-art-dev` → `.../openshift/release`; `ocp-release` → `.../release` and/or `release-images` |
| Quay only had **4.18.6** release tags | `skopeo list-tags` showed `4.18.6-x86_64*` only |
| Upgrade stuck on missing digest | `manifest unknown` for `sha256:f015c4401dbbe...` |
| Failing image = `cluster-config-api` | From `oc adm release info ... \| grep config` |
| Init container never started | Empty Container ID → `oc logs` useless; use `oc describe` / Events |
| CVO progress 65–69/906 is payload resource count | Not “69 pods” |

---

## 4. Unknowns (must be resolved per environment / 2nd cluster)

| Unknown | How to resolve |
|---------|----------------|
| Exact recommended z-stream on upgrade day | `oc adm upgrade` after channel set |
| Whether target payload already mirrored | `skopeo list-tags` + digest inspect for key images |
| Whether utility host has pull access to quay.io for mirroring | Test `podman login` / `oc-mirror` / `oc adm release mirror` |
| Disk headroom on Quay volume | `df -h` / `du` on quay-storage before mirror |
| Pull-secret validity for mirroring host | `jq .auths` / trial pull |
| Second SNO hostname, VIP, registry shared vs dedicated | Inventory checklist in `04-second-sno-cluster.md` |
| Whether CatalogSource images for operators need refresh | Compare CSVs to target OCP |
| Proxy / firewall differences between SNO1 and SNO2 | Node `curl` / DNS tests |
| Backup destination path and capacity | Confirm `/home/core` or NFS before etcd backup |

---

## 5. Architecture (logical)

```text
                    ┌─────────────────────────────┐
                    │  Workstation (oc client)    │
                    │  student@workstation        │
                    └──────────────┬──────────────┘
                                   │ kube-apiserver
                                   ▼
                    ┌─────────────────────────────┐
                    │  SNO: master01              │
                    │  OCP 4.18.x                 │
                    │  CVO / MCO / Operators      │
                    └──────────────┬──────────────┘
                                   │ ICSP digest mirrors
                                   ▼
                    ┌─────────────────────────────┐
                    │ registry.ocp4.example.com   │
                    │ :8443  (nginx → Quay)       │
                    │ repos:                      │
                    │  openshift/release          │
                    │  openshift/release-images   │
                    │  operator org mirrors       │
                    └──────────────┬──────────────┘
                                   │
                                   ▼
                              152GB blobs
```

### Image rewrite path (critical)

```text
quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:DIGEST
        │
        │  ICSP
        ▼
registry.ocp4.example.com:8443/openshift/release@sha256:DIGEST

quay.io/openshift-release-dev/ocp-release@sha256:DIGEST
        │
        ▼
registry.ocp4.example.com:8443/openshift/release-images@sha256:DIGEST
   (and/or .../openshift/release depending on ICSP entries)
```

---

## 6. Decision gates (must pass)

| Gate | Pass criteria |
|------|---------------|
| G0 Health | Available=True, Progressing=False, Degraded=False; MCP Updated |
| G1 Registry path | Node → registry `/v2/` TLS OK + 401 |
| G2 Trust | `registry-config` present; Podman login works with TLS verify |
| G3 Mirror content | Target release tags **and** critical digests present (`skopeo inspect`) |
| G4 Operators | Subscriptions/CSVs healthy; catalog reachable |
| G5 Backup | etcd backup completed and copied off-node if possible |
| G6 Channel/graph | `stable-4.18` (or chosen channel); recommended target listed |
| G7 Upgrade | Only then `oc adm upgrade --to=<listed-version>` |

**For the second SNO: never start G6/G7 until G3 passes.**

---

## 7. Success definition

Upgrade is complete when **all** are true:

1. `oc get clusterversion` shows target version, Available=True, Progressing=False, Failing=False  
2. All `clusteroperators` Available=True, Progressing=False, Degraded=False  
3. MCP master Updated=True, Updating=False, Degraded=False  
4. Node Ready (not SchedulingDisabled)  
5. MetalLB + LVMS CSVs Succeeded  
6. Sample app / console reachable (lab-appropriate smoke test)  
7. History entry for target version `state: Completed`
