# SOP — Pre-Upgrade Checklist (Categorical Gates)

Work through every category in order. **Each gate must be GREEN before moving
to the next.** Do not skip ahead because "it worked like that on cluster #1."

Legend: 🟢 pass / 🟡 needs attention / 🔴 blocking — do not proceed.

## Gate 0 — Access & tooling

- [ ] `oc` CLI matches (or is newer than) the target OpenShift version.
- [ ] `KUBECONFIG` points at cluster #2, confirmed via
      `oc whoami --show-server`.
- [ ] `podman`, `skopeo`, and (if mirroring is needed) `oc-mirror` are
      installed on the workstation/registry host and their versions are
      recorded.
- [ ] SSH/console access to the registry host and to the SNO node
      (`oc debug node/<node>`) is confirmed working.
- [ ] Run: `bash scripts/00-preflight-check.sh` and attach its output to the
      change record.

## Gate 1 — Cluster baseline health

- [ ] `oc get clusterversion version -o wide` → `AVAILABLE=True`,
      `PROGRESSING=False`.
- [ ] `oc get clusterversion version -o yaml` → condition `Failing=False`.
- [ ] `oc get nodes` → every node `Ready` (no `SchedulingDisabled`/`NotReady`).
- [ ] `oc get clusteroperators` → every operator
      `AVAILABLE=True PROGRESSING=False DEGRADED=False`.
- [ ] `oc get mcp` → every pool `UPDATED=True UPDATING=False DEGRADED=False`.
- [ ] `oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded`
      → empty, or every non-Running pod explained and accepted.
- [ ] `oc get pvc -A` and `oc get pv` reviewed — no unexpected `Pending`/`Lost`.
- [ ] `oc get events -A --sort-by='.lastTimestamp' | tail -50` reviewed for
      pre-existing noise so it isn't confused with upgrade-caused errors later.

> **Do not proceed if the baseline is already unhealthy.** Fix baseline
> issues first; an upgrade will not repair a broken cluster and will make
> troubleshooting far harder.

## Gate 2 — Registry / mirror trust (host level)

This is the exact class of problem that blocked login on cluster #1 (Podman
had no CA trust even though OpenShift did).

- [ ] Extract the CA chain the cluster trusts:
      `oc get configmap registry-config -n openshift-config -o jsonpath='{.data.<key>}' > registry-ca-bundle.pem`
      (the ConfigMap key is the registry host:port with dots/colons escaped,
      e.g. `registry.ocp4.example.com..8443` — **do not rename this key**).
- [ ] Split and identify intermediate/root CA certs
      (`awk` + `openssl x509 -subject -issuer`), confirm the chain terminates
      in a self-signed root.
- [ ] Install the CA chain into the registry host's system trust store
      (`/etc/pki/ca-trust/source/anchors/`, then `update-ca-trust extract`).
- [ ] Install the CA into the Podman/CRI-specific trust directory:
      `/etc/containers/certs.d/<registry-host>:<port>/ca.crt`.
- [ ] Validate with `openssl s_client -CAfile /etc/pki/tls/certs/ca-bundle.crt`
      → `Verify return code: 0 (ok)`.
- [ ] `podman login <registry-host>:<port>` succeeds **without**
      `--tls-verify=false`.
- [ ] From an OpenShift node (`oc debug node/<node> -- chroot /host`),
      `curl -I https://<registry-host>:<port>/v2/` returns `401 Unauthorized`
      (this is the expected "healthy but needs auth" response, not an error).
- [ ] Run: `bash scripts/01-registry-trust-setup.sh` to automate the above and
      record the result.

## Gate 3 — Mirror configuration inventory (cluster side)

- [ ] Inventory existing mirroring objects:
      `oc get imagecontentsourcepolicy,imagedigestmirrorset,imagetagmirrorset -o yaml`.
- [ ] Confirm every `source → mirror` mapping resolves to a registry host that
      is reachable and trusted (Gate 2).
- [ ] Decide: **stay on ICSP** (if that's what's already deployed and
      working) or **migrate to IDMS/ITMS** (Red Hat's recommended mechanism;
      existing ICSPs keep working, so migration is optional, not mandatory,
      for a routine z-stream upgrade). Do not migrate mechanisms in the same
      change window as the version upgrade unless required — it adds an
      independent variable to a rollout you need to be able to reason about.
- [ ] If IDMS/ITMS will be used going forward, stage (but do not yet apply)
      `manifests/idms-openshift-release.yaml` and
      `manifests/idms-operators.yaml`.

## Gate 4 — Update graph / target version

- [ ] Confirm current channel: `oc get clusterversion version -o jsonpath='{.spec.channel}'`.
- [ ] If unset, set the appropriate channel for a disconnected 4.18 cluster:
      `oc patch clusterversion version --type=merge -p '{"spec":{"channel":"stable-4.18"}}'`.
- [ ] Wait for `RetrievedUpdates=True`:
      `oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="RetrievedUpdates")].status}'`.
- [ ] Run `oc adm upgrade` and record the **exact recommended version(s)**.
      **Use the version the cluster recommends — never hard-code a version
      number from a previous run or from documentation.**
- [ ] Record the target release digest:
      `oc adm upgrade` output, or
      `oc get clusterversion version -o jsonpath='{.status.availableUpdates}'`.
- [ ] Run: `bash scripts/03-set-channel-and-check-graph.sh` and archive the
      output (this becomes your authoritative target-version record for the
      rest of the change).

## Gate 5 — Mirror **content** validation against the exact target digest set ⚠️ (This gate was skipped on cluster #1 and caused the stall)

This is the single most important gate in this entire SOP.

- [ ] Obtain the target release image reference (digest) from Gate 4.
- [ ] `oc adm release info <target-release-pullspec>` from a host that can
      reach the mirror (or `quay.io` if briefly reachable) to enumerate every
      component image digest in the payload (typically 750+ images).
- [ ] For **every** component digest, verify it resolves through the mirror:
      `skopeo inspect docker://<mirror-host>:<port>/<mapped-repo>@<digest>`.
      Do **not** rely on tag listings (`skopeo list-tags`) alone — release
      payloads pin digests, and a repo can have tags for one version while
      missing digests for another.
- [ ] Automate this with `scripts/02-inventory-mirror-content.sh
      --release <target-pullspec>` which diffs the full digest list from
      `oc adm release info` against what actually resolves on the mirror and
      prints a pass/fail per image.
- [ ] If **any** digest is missing (this is exactly what happened on cluster
      #1 — the mirror only had 4.18.6 content, not 4.18.52), **stop** and
      run the mirroring procedure in Gate 5a before touching `ClusterVersion`.
- [ ] Also validate the operator catalog/bundle images for MetalLB and LVM
      Storage (and any other installed operator) are present for the
      target-compatible channel, using the same digest-resolution method
      against their ICSP/IDMS mirror mappings.
- [ ] Confirm registry storage headroom: a full 4.18 release plus operator
      indexes is commonly 150–250 GB; confirm free space before mirroring
      (`df -h` on the Quay storage volume mount).

### Gate 5a — Mirror the target release (only if Gate 5 found gaps)

- [ ] Build (or reuse) an `oc-mirror` v2 `ImageSetConfiguration` for the
      exact target release — see `manifests/imagesetconfig-release.yaml`.
- [ ] Run `scripts/04-mirror-missing-release-images.sh` (wraps
      `oc mirror -c imagesetconfig-release.yaml --workspace file://<dir>
      docker://<mirror-host>:<port>` in mirror-to-mirror or mirror-to-disk
      mode as appropriate for this environment's connectivity).
- [ ] Apply the IDMS/ITMS (or updated ICSP) that `oc-mirror` generates —
      review the generated manifests before applying; do not blindly
      `oc apply -f` without diffing against the existing mirror config from
      Gate 3.
- [ ] Re-run Gate 5's digest-resolution check until it is 100% green.

## Gate 6 — Operator compatibility

- [ ] `oc get subscriptions -A -o wide`, `oc get csv -A`,
      `oc get catalogsource -A`.
- [ ] For MetalLB Operator and LVM Storage Operator (and any others), confirm
      the subscribed channel has an available CSV that is compatible with
      the target OpenShift version (check vendor release notes / OperatorHub
      compatibility matrix — do this manually, it is not automatable from
      inside a disconnected cluster).
- [ ] Confirm the `CatalogSource` (e.g. `gls-catalog-cs`) itself is mirrored
      for the target index version if a catalog update is also required.
- [ ] If any operator has no compatible path, decide and document whether to
      (a) update the operator first, (b) accept a temporary compatibility
      gap the vendor documents as safe, or (c) hold the platform upgrade.

## Gate 7 — Backup & rollback readiness

- [ ] Confirm `cluster-backup.sh` exists on the control-plane node:
      `oc debug --as-root node/<node> -- chroot /host ls -l /usr/local/bin/cluster-backup.sh`.
- [ ] Take a fresh etcd backup **immediately before** starting the upgrade
      (not days before): `scripts/09-etcd-backup.sh`.
- [ ] Copy the backup off-node (to the workstation or a separate backup
      target) — a backup that lives only on the node you are about to
      upgrade is not a backup.
- [ ] Document the current version/digest (`oc get clusterversion -o
      jsonpath='{.status.history[0]}'`) as the rollback reference point.
- [ ] Confirm you understand SNO restore limitations (Constraint C6): the
      backup exists for forensics and potential reinstall-and-restore, not
      necessarily a fast in-place rollback. Treat "prevent the failure" (Gates
      0–6) as far higher leverage than "recover from the failure" on SNO.

## Sign-off

| Gate | Owner | Result | Timestamp | Notes |
|---|---|---|---|---|
| 0 Access & tooling | | | | |
| 1 Baseline health | | | | |
| 2 Registry trust | | | | |
| 3 Mirror config inventory | | | | |
| 4 Update graph/target | | | | |
| 5 Mirror content validation | | | | |
| 6 Operator compatibility | | | | |
| 7 Backup & rollback readiness | | | | |

**Do not start `docs/03-SOP-Execution-Flow.md` until every row above is
green.**
