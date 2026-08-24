# Best Practices — Disconnected OpenShift SNO Upgrades

## Planning

1. **Validate mirror content against the exact target digest set before you
   touch `ClusterVersion`.** This single practice would have prevented the
   cluster #1 stall entirely. Tag-level checks (`skopeo list-tags`) are not
   sufficient; release payloads pin digests.
2. **Let the cluster's own update graph choose the target version.** Never
   hard-code a version from documentation or from a previous run — Cincinnati
   graphs change, and a version that was a direct edge yesterday may not be
   today (and vice versa).
3. **Treat channel changes and mirroring-mechanism migrations (ICSP→IDMS) as
   separate changes from the version upgrade** unless there's a specific
   reason to combine them. Fewer simultaneous variables makes root-causing a
   stall far faster.
4. **Capture a full baseline before starting** (ClusterVersion, CO, MCP,
   nodes, events, PVC/PV) so that upgrade-time troubleshooting can
   distinguish "caused by the upgrade" from "was already like that."
5. **Right-size registry storage ahead of time.** A full 4.18 release plus
   operator catalogs is commonly 150–250 GB; check headroom before mirroring,
   not after it fails partway through.

## Trust & security

6. **Keep host-level container trust (`/etc/containers/certs.d`) and
   cluster-level trust (`additionalTrustedCA`) in sync deliberately** — they
   are independent stores and one being correct does not imply the other is.
7. **Never use `--tls-verify=false` / `-k` as a permanent fix.** It's fine as
   a *diagnostic* step to isolate whether a failure is TLS-related, but the
   durable fix is always to install the correct CA chain.
8. **Prefer installing the intermediate + root CA, not the leaf certificate,**
   into trust stores — the leaf changes on renewal, the CA chain is stable
   for years.

## Mirroring

9. **Use `oc-mirror` v2 with an `ImageSetConfiguration` scoped to the release
   range you actually need** (e.g. `minVersion`/`maxVersion` bracketing the
   current and target versions) rather than mirroring entire channels
   unnecessarily — this saves enormous time and storage on repeat upgrades.
10. **Review generated IDMS/ITMS/ICSP manifests before applying them.** Diff
    against what's already on the cluster; don't blindly overwrite an
    existing, working mirror configuration.
11. **Keep a per-release archive of what you mirrored** (imageset config +
    resulting digest list) so the next upgrade's Gate 5 check has a fast,
    authoritative "known good" baseline to diff against.
12. **Prefer digest-only mirroring (`pull-from-mirror = "digest-only"`)** for
    release/operator content, matching what OpenShift itself expects — this
    is what was already correctly configured on cluster #1's node-level
    `registries.conf`.

## Execution

13. **Always open the multi-pane monitoring layout before issuing the
    upgrade command**, not after something looks wrong — you want to see the
    first status transition, not reconstruct it after the fact.
14. **Distinguish "expected disruption" from "stall."** On SNO in particular,
    a temporary `NotReady` node and unreachable API during the mandatory
    reboot are normal; treat only a stall with an explicit blocking message
    (or a reboot that exceeds a sane time budget) as actionable.
15. **Let CVO/MCO own node lifecycle.** Never manually cordon, drain, delete
    CVO-managed pods repeatedly, or restart the CVO deployment during a
    normal rollout — these actions do not address the underlying blocker and
    can complicate reconciliation.
16. **When a stall is fixed by mirroring a missing image, let the existing
    retry/backoff resume the rollout** (or do at most one forced pod delete)
    rather than restarting the upgrade end-to-end.

## Operators & workloads

17. **Check operator update compatibility (channel/CSV) against the target
    OpenShift version before the platform upgrade**, not after — a
    platform-level upgrade can leave an operator with no valid path forward
    if this isn't checked in advance.
18. **Mirror updated catalog/bundle images together with the platform
    release** if the operator's compatible version requires a newer index —
    don't assume the existing catalog mirror will happen to already contain
    it.

## Backup & change management

19. **Take the etcd backup immediately before starting**, not "recently" —
    and copy it off-node. A backup that only exists on the node you are
    about to upgrade is not a backup.
20. **On SNO, weight prevention over recovery.** Restore options are limited
    with a single member; the pre-upgrade gates in this SOP are your primary
    risk control, not the backup.
21. **Record every deviation from the SOP** (what was different, why, what
    happened) and feed it back into the SOP before the next cluster — this
    is how a one-off troubleshooting session becomes an organizational
    capability instead of tribal knowledge.

## Communication & auditability

22. **Timestamp everything** (gate sign-offs, stall start/end, remediation
    actions) — post-incident review is far easier with a timeline than with
    "it took a while and then it worked."
23. **Never run an unfamiliar command against a live CVO rollout "to see what
    happens."** Every corrective action in this kit was chosen because it is
    non-destructive and reversible; ad hoc commands against a mid-rollout
    cluster are the highest-risk category of action in this entire
    procedure.
