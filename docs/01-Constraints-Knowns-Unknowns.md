# Constraints, Knowns, and Unknowns

Use this section to separate facts that are **fixed by the environment**
(constraints), facts that are **already proven from cluster #1** (knowns),
and facts that **must be re-discovered on cluster #2** before proceeding
(unknowns). Do not assume a known from cluster #1 automatically applies to
cluster #2 — always re-verify with the discovery scripts.

## Constraints (cannot be changed, must be designed around)

| # | Constraint | Implication |
|---|---|---|
| C1 | Cluster is **disconnected**: no direct internet egress from nodes | Every image the target release/operators need must exist in the local mirror **before** the upgrade starts |
| C2 | Cluster is **Single Node OpenShift (SNO)**: one node is simultaneously control-plane + worker | During the MCO/RHCOS update step the API server and all workloads become briefly unavailable during the mandatory reboot — there is no second node to fail over to |
| C3 | CVO applies the release payload as an **atomic, ordered DAG** of ~900 resources | A single missing image blocks the whole rollout at that resource; it does not skip ahead |
| C4 | Image references inside a release payload are **digests, not tags** | You cannot "fix" a missing image by mirroring *a* tag; you must mirror the **exact digest set** for the target release |
| C5 | Upgrades can only move along the **official Cincinnati update graph** for the configured channel (e.g., `stable-4.18`) | You cannot arbitrarily jump versions; the graph decides valid hops (e.g. 4.18.6 → 4.18.52, not straight to 4.18.53, if 4.18.53 isn't offered as a direct edge yet) |
| C6 | etcd backup/restore has **limited support on SNO** (no other member to restore to) | Backup is still mandatory for forensics/rebuild, but do not assume a guaranteed in-place restore path |
| C7 | Registry host trust store and OpenShift's cluster-wide trust store (`additionalTrustedCA`) are **independent** | Fixing one does not fix the other; both must be validated |
| C8 | OLM operators must have a **compatible channel/CSV path** for the target OpenShift minor/patch | An operator with no update available for the new OCP version can block or degrade after the platform upgrade |

## Knowns (proven true on cluster #1 — treat as reference, re-verify on #2)

| # | Known fact | Evidence |
|---|---|---|
| K1 | Mirror registry is Quay 3.8.12 behind nginx at `registry.<domain>:8443` | `podman ps`, `curl -I https://…/v2/` → `server: nginx/1.20.1` |
| K2 | Registry TLS chain: leaf → `Red Hat Training Certificate Authority` → `Red Hat Training Trust Services` (root), leaf cert valid until 2029-01-07 | `openssl x509 -issuer -subject` walk of `registry-config` ConfigMap |
| K3 | Cluster trusts the registry via `openshift-config/registry-config` + `image.config.openshift.io/cluster.spec.additionalTrustedCA` | `oc get configmap registry-config -n openshift-config` |
| K4 | Podman/host-level trust is **separate** and was empty by default | `/etc/containers/certs.d/` was empty until manually populated |
| K5 | Cluster mirroring uses **legacy ICSP** (3 objects: `image-policy`, `operator-<ts>`, `release-<ts>`), no IDMS/ITMS present | `oc get imagecontentsourcepolicy,imagedigestmirrorset,imagetagmirrorset` |
| K6 | Two OLM operators matter: **MetalLB Operator** (`metallb-system`, channel `stable`) and **LVM Storage Operator** (`openshift-storage`, channel `stable-4.18`), both from `CatalogSource` `gls-catalog-cs` in `openshift-marketplace` | `oc get subscriptions -A -o wide` |
| K7 | Prior to upgrade, cluster was healthy: all ClusterOperators `Available/​!Progressing/​!Degraded`, MCPs updated, one `Ready` node | Baseline warm-up capture |
| K8 | Channel was **unset** (`spec.channel=""`) pre-upgrade — `RetrievedUpdates=False/NoChannel` | `oc get clusterversion version -o yaml` |
| K9 | Setting `stable-4.18` immediately produced a recommended-update graph and the operator proceeded straight to **4.18.52** | `oc adm upgrade` output after channel patch |
| K10 | Upgrade stalled at CVO payload step **65/906** on `Deployment openshift-config-operator/openshift-config-operator` because its init container `openshift-api` could not pull `quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:f015c440...` (component `cluster-config-api`) | `oc describe pod`, CVO logs |
| K11 | The mirror only contained **4.18.6** release content; `skopeo list-tags` against `openshift/release-images` on the mirror returned exactly `4.18.6-x86_64` | Direct skopeo query against registry host |
| K12 | Both the direct Quay pull (`unauthorized`) and the mirror pull (`manifest unknown`) failed for the missing digest — this is the disconnected-cluster signature of "image never mirrored," not a credentials or network problem | kubelet event text + `crictl pull` results |

## Unknowns — must be re-discovered on cluster #2 (never assume)

| # | Unknown | How to discover | Script/Command |
|---|---|---|---|
| U1 | Current OCP version and channel on cluster #2 | Never assume it matches cluster #1 (patch level may differ) | `scripts/00-preflight-check.sh` |
| U2 | Whether cluster #2 uses ICSP, IDMS/ITMS, or a mix | Inventory before touching mirror config | `oc get imagecontentsourcepolicy,imagedigestmirrorset,imagetagmirrorset -o yaml` |
| U3 | Whether the shared mirror registry (if reused from cluster #1) already contains the target release for cluster #2, or needs a fresh mirror pass | `skopeo list-tags` / digest probe against every referenced repo | `scripts/02-inventory-mirror-content.sh` |
| U4 | Exact target version the Cincinnati graph will recommend once the channel is set (may not be the newest GA release if it's not yet a direct edge) | `oc adm upgrade` after setting channel, **before** issuing `--to` | `scripts/03-set-channel-and-check-graph.sh` |
| U5 | Which operators are installed and whether their current channel/CSV has an update path compatible with the target OCP version | `oc get subscriptions -A -o wide`, vendor compatibility matrix | manual + `oc get csv -A` |
| U6 | Registry host trust state (may already be fixed if this is a shared registry, or may be a fresh host) | Re-run the trust validation, do not assume it is already fixed | `scripts/01-registry-trust-setup.sh` |
| U7 | Available local disk/registry storage headroom for a new release's worth of images (was 152 GB used out of an unknown total on cluster #1) | `df -h` on the registry host + Quay storage volume `du` | `scripts/02-inventory-mirror-content.sh` |
| U8 | Whether cluster #2 has any workloads/PVs/pending pods that would make "unhealthy before the upgrade" look like "broken by the upgrade" | `oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded`, `oc get events -A` | `scripts/00-preflight-check.sh` |
| U9 | Network path from cluster #2's nodes to the mirror registry (same registry host? new host? different port/hostname?) | `oc debug node/<node> -- curl -I https://<registry>/v2/` | `scripts/00-preflight-check.sh` |
| U10 | Whether an `oc-mirror` workflow already exists for this environment (imageset config, cache dir, credentials) or must be created from scratch | Check for `~/.oc-mirror`, existing `ImageSetConfiguration` YAMLs, mirror-to-disk archives | manual discovery, then `manifests/imagesetconfig-release.yaml` |

## Decision rule

> **If any Unknown cannot be resolved to a definite, verified answer, treat
> it as a blocking gate.** Do not proceed to the upgrade execution phase
> (`docs/03-SOP-Execution-Flow.md`) until every row in the Pre-Upgrade
> Checklist (`docs/02-SOP-Preupgrade-Checklist.md`) is green.
