# SOP — Post-Upgrade Validation & Sign-off

Run `bash scripts/08-post-upgrade-validate.sh` to automate the checks below,
then complete the manual review items.

## Category A — Platform version & health

- [ ] `oc get clusterversion version -o wide` shows target version,
      `AVAILABLE=True`, `PROGRESSING=False`.
- [ ] `oc get clusterversion version -o jsonpath='{range .status.history[*]}{.version}{" | "}{.state}{"\n"}{end}'`
      shows the new version with state `Completed`.
- [ ] `oc get co` — all `AVAILABLE=True PROGRESSING=False DEGRADED=False`.
- [ ] `oc get mcp` — all pools `UPDATED=True UPDATING=False DEGRADED=False`,
      and `MACHINECOUNT == READYMACHINECOUNT == UPDATEDMACHINECOUNT`.
- [ ] `oc get nodes -o wide` — node(s) `Ready`, kernel/OS image reflects the
      new RHCOS build, kubelet version matches the new Kubernetes version
      shipped with the target OpenShift release.

## Category B — Workload health

- [ ] `oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded`
      is empty (or every entry is understood/expected, e.g. `Completed`
      Jobs).
- [ ] `oc get events -A --sort-by='.lastTimestamp' | tail -50` shows no
      recurring `Warning` events tied to the new version.
- [ ] Application/ingress smoke test: hit a representative Route via the
      MetalLB-provisioned LoadBalancer IP and confirm a 200-class response.
- [ ] PVC/PV state unchanged from pre-upgrade baseline (`oc get pvc -A`,
      `oc get pv`).

## Category C — Operator/OLM health

- [ ] `oc get csv -A` — MetalLB Operator and LVM Storage Operator (and any
      others) report `Succeeded` at the expected version.
- [ ] `oc get subscriptions -A -o wide` — no subscription stuck in
      `UpgradePending`/`UpgradeFailed`.
- [ ] Functional check: MetalLB `L2Advertisement`/`IPAddressPool` still
      active and an example `Service type=LoadBalancer` still has an
      external IP; LVM Storage `LVMCluster` is `Ready` and a test PVC still
      binds.

## Category D — Disconnected registry / mirror hygiene

- [ ] Re-capture the mirror content inventory
      (`scripts/02-inventory-mirror-content.sh`) and archive it alongside
      this run's change record — this becomes next cycle's "known good"
      baseline.
- [ ] Confirm registry storage headroom after the mirror pass (should have
      grown by roughly one release's worth of images; note the new total).
- [ ] Confirm no orphaned `oc-mirror` cache/workspace directories are left
      filling disk on the workstation/registry host.

## Category E — Backup & documentation

- [ ] Take a **post-upgrade** etcd backup and store it alongside the
      pre-upgrade one (`scripts/09-etcd-backup.sh`).
- [ ] Update the cluster's version/digest record used for rollback reference.
- [ ] File the completed sign-off table (Gate table from the pre-upgrade
      checklist, plus this document's checkboxes) in the change ticket.
- [ ] Note any deviation from this SOP (what happened, what was done
      differently, why) so the SOP can be improved for the next cluster.

## Sign-off

| Category | Result | Verified by | Timestamp |
|---|---|---|---|
| A — Platform version & health | | | |
| B — Workload health | | | |
| C — Operator/OLM health | | | |
| D — Registry/mirror hygiene | | | |
| E — Backup & documentation | | | |

**Upgrade is only considered complete once all five categories are signed
off.**
