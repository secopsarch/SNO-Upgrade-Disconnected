# Executive Summary

## Scenario

A Single Node OpenShift (SNO) cluster (`master01`), running **OpenShift
4.18.6**, needed to be upgraded to the latest available **4.18.z** release
(4.18.52 → 4.18.53 at time of writing) entirely inside a **disconnected /
mirrored lab environment**. All container images are served from a local
**Quay registry** (`registry.ocp4.example.com:8443`) that the cluster trusts
through legacy **ImageContentSourcePolicy (ICSP)** objects.

## What happened on cluster #1 (the reference run)

1. Podman on the registry host could not log in to Quay (`x509: certificate
   signed by unknown authority`) because the host's local trust store never
   received the Quay CA chain, even though OpenShift itself already trusted
   it via `additionalTrustedCA`. This was fixed by extracting the intermediate
   + root CA from the `registry-config` ConfigMap and installing it under
   `/etc/pki/ca-trust` and `/etc/containers/certs.d/<registry>:<port>/ca.crt`.
2. A full baseline/warm-up pass confirmed the cluster was healthy (all
   ClusterOperators `Available=True/Progressing=False/Degraded=False`, MCPs
   updated, no NoChannel-related surprises) and inventoried the existing
   mirror configuration (3 ICSPs, no IDMS/ITMS) and the two customer
   operators (MetalLB, LVM Storage) installed from a custom `CatalogSource`.
3. The cluster's channel was set to `stable-4.18`, the CVO calculated the
   graph, and the operator initiated an update **directly to 4.18.52** (the
   next recommended hop from 4.18.6), reaching 7% (69/906 payload
   manifests applied) before stalling.
4. The stall was traced through the CVO logs → ClusterOperator `config` →
   Deployment `openshift-config-operator` → Pod →
   **init container `openshift-api` stuck in `Init:ImagePullBackOff`**.
5. Root cause: the init container needed
   `quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:f015c440...`
   (the `cluster-config-api` component of the 4.18.52 payload). The node's
   `registries.conf` correctly redirected that pull to the mirror
   (`registry.ocp4.example.com:8443/openshift/release@sha256:f015c440...`),
   but the mirror registry responded `manifest unknown` — **the 4.18.52
   release content had never been mirrored into Quay**. Direct pulls from
   the public `quay.io` also failed (`unauthorized`), as expected in a
   disconnected environment.
6. `skopeo list-tags` against the mirror confirmed the registry only held
   **4.18.6** release content (`release-images` repo had exactly one tag:
   `4.18.6-x86_64`). This is unambiguous: **the mirror was never refreshed
   for the target release before the upgrade was started.**

The reference conversation ends at the point where the root cause is fully
diagnosed but **before the remediation (mirroring the missing content) was
executed**. This SOP closes that gap and turns the whole exercise into a
repeatable, pre-flighted procedure for cluster #2 (and beyond).

## Goal of this SOP

Give any operator — with **no prior context and no live support** — a
deterministic, checklist-driven path to:

1. Validate every prerequisite **before** touching `ClusterVersion` (this is
   the step cluster #1 skipped: mirror-content validation against the actual
   target digest set).
2. Execute the upgrade with the correct monitoring in place so a stall is
   detected in minutes, not by chance.
3. Diagnose and remediate the specific "mirror is missing a required image"
   failure mode (and other common failure modes) using ready-made scripts
   and manifests instead of ad hoc commands.
4. Validate the cluster and its operators post-upgrade and formally sign off.

## Outcome definition ("Done" criteria)

- `oc get clusterversion version` shows the target version with
  `Available=True`, `Progressing=False`, `Degraded=False`, and history state
  `Completed` (not `Partial`).
- `oc get co` — zero ClusterOperators degraded; all `AVAILABLE=True`.
- `oc get mcp` — all pools `UPDATED=True`, `UPDATING=False`, `DEGRADED=False`.
- `oc get nodes` — node(s) `Ready` (no `SchedulingDisabled`, no `NotReady`).
- MetalLB and LVM Storage operator CSVs report `Succeeded` at a version
  compatible with the new OpenShift release.
- A post-upgrade etcd backup exists.
- The mirror registry content inventory has been re-captured and archived
  for the next upgrade cycle.
