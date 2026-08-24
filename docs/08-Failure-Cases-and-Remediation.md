# Failure Cases Catalog

Each entry: **Trigger → Symptom → Root cause → Remediation → Prevention**.

## FC-1 — Podman cannot log in to the mirror (`x509: certificate signed by unknown authority`)

- **Trigger:** Fresh registry host, or host trust store never populated.
- **Symptom:** `podman login <registry>:<port>` fails with an x509 error,
  even though `oc get configmap registry-config -n openshift-config` shows
  a valid, cluster-trusted CA chain.
- **Root cause:** OpenShift's `additionalTrustedCA` and the registry host's
  OS/Podman trust stores are independent. The cluster trusting the registry
  does not mean the registry *host itself* trusts its own certificate chain
  from Podman's point of view.
- **Remediation:** Extract the CA chain from `registry-config`, identify the
  intermediate/root certs via `openssl x509 -subject -issuer`, install into
  `/etc/pki/ca-trust/source/anchors/` + `update-ca-trust extract`, and into
  `/etc/containers/certs.d/<host>:<port>/ca.crt`. Re-test with
  `openssl s_client -CAfile ...` before retrying `podman login`.
- **Prevention:** Bake CA installation into registry-host provisioning
  automation; include it in Gate 2 of every upgrade cycle regardless of
  whether it "should" already be fixed.

## FC-2 — `oc adm upgrade` reports `NoChannel` and no available updates

- **Trigger:** `spec.channel` was never set (common on freshly installed
  disconnected clusters).
- **Symptom:** `RetrievedUpdates=False`, reason `NoChannel`; `availableUpdates`
  is `null`.
- **Root cause:** The CVO cannot calculate a graph without a channel; an
  empty channel is valid for restricted clusters that don't use the public
  recommendation service, but it means you must explicitly opt in.
- **Remediation:** `oc patch clusterversion version --type=merge -p
  '{"spec":{"channel":"stable-4.18"}}'`, then wait for
  `RetrievedUpdates=True`.
- **Prevention:** Document the intended channel per cluster as part of its
  build record so this isn't rediscovered ad hoc during every upgrade.

## FC-3 — CVO stalls with `Unable to apply <ver>: workload not rolled out` / `ImagePullBackOff` on a payload component (the cluster #1 incident)

- **Trigger:** Target release was never (fully) mirrored into the local
  registry before the upgrade was started.
- **Symptom:** Progress counter freezes (e.g. `65/906` or `69/906`); a
  specific ClusterOperator's Deployment pod is stuck
  `Init:<container>:ImagePullBackOff`; kubelet events show
  `manifest unknown` from the mirror and `unauthorized` from the public
  registry for the same digest.
- **Root cause:** The mirror registry's content lagged the release the CVO
  was told to install; the release payload requires an exact digest set,
  and even one missing digest blocks that payload resource from completing.
- **Remediation:** Identify the exact digest and target release
  (`oc get clusterversion version -o jsonpath='{.status.desired.image}'`),
  build/run an `ImageSetConfiguration` for that release, mirror it with
  `oc-mirror`, and let the kubelet/CVO retry loop resume automatically (or
  force one pod deletion). Full sequence in
  `docs/05-Troubleshooting-Guide.md` Section 3.
- **Prevention:** Gate 5 of the pre-upgrade checklist — digest-level mirror
  content validation against the exact target release — **before** setting
  the channel or issuing `oc adm upgrade`.

## FC-4 — Operator has no compatible update path after the platform upgrade

- **Trigger:** OLM operator's subscribed channel doesn't offer a CSV
  compatible with the new OpenShift minor/patch version.
- **Symptom:** ClusterOperator platform components are healthy, but the
  operator's CSV is stuck, or the operator becomes degraded/incompatible
  post-upgrade (e.g., admission webhook mismatches, CRD version drift).
- **Root cause:** Operator compatibility wasn't checked against the target
  OpenShift version before the platform upgrade proceeded.
- **Remediation:** Consult the vendor's compatibility matrix; update the
  operator's channel/subscription (mirroring the new catalog/bundle images
  first if disconnected) or roll back the platform upgrade if the gap is
  unacceptable and no compatible operator version exists yet.
- **Prevention:** Gate 6 — verify compatibility for every installed operator
  before Gate 7 (backup) and certainly before Step 3 of execution
  (`oc adm upgrade --to=...`).

## FC-5 — SNO node stays `NotReady` far longer than a normal reboot

- **Trigger:** RHCOS update requires a reboot; on SNO there's no other node
  to mask the outage.
- **Symptom:** API/console unreachable; `oc get nodes` fails entirely
  (expected for a bounded window); the outage continues well past the
  typical 10–15 minute reboot budget.
- **Root cause (varies):** boot failure from the new RHCOS build, hardware
  issue, storage/firmware problem, or a hung shutdown of a workload with a
  long `terminationGracePeriodSeconds`.
- **Remediation:** Use console/BMC/IPMI access (out-of-band, since `oc` is
  unavailable while the node is down) to check boot progress; do not
  power-cycle repeatedly without first observing the console output; if the
  node is hung mid-shutdown, allow the configured grace period to elapse
  before escalating.
- **Prevention:** Confirm out-of-band console/BMC access as part of Gate 0
  (Access & tooling) before starting any SNO upgrade — you cannot use `oc`
  to debug a node that isn't `Ready`.

## FC-6 — Registry storage runs out of space mid-mirror

- **Trigger:** Registry host's storage volume wasn't sized for an
  additional full release + operator index.
- **Symptom:** `oc-mirror` or Quay writes fail partway through; partial/
  corrupt blobs; subsequent digest validation (Gate 5) still fails after a
  "successful" mirror run.
- **Root cause:** Insufficient free space was not checked before mirroring.
- **Remediation:** Free space (prune old, no-longer-needed release content
  only after confirming nothing still depends on it) or expand storage;
  re-run the mirror from a clean state rather than assuming a partial run
  can be resumed blindly — verify with Gate 5's digest check either way.
- **Prevention:** Explicit storage headroom check in Gate 5, before Gate 5a
  mirroring is executed.

## FC-7 — ICSP/IDMS mapping points at the wrong mirror repository

- **Trigger:** Manual or historical mirror configuration doesn't match the
  actual repository layout the images were pushed to.
- **Symptom:** `manifest unknown` even though the image genuinely exists in
  the registry, just under a different repository path than the mirror
  mapping expects.
- **Root cause:** Source→mirror mapping (ICSP/IDMS `repositoryDigestMirrors`)
  doesn't match where the content was actually mirrored to.
- **Remediation:** Compare `oc get imagecontentsourcepolicy/imagedigestmirrorset
  -o yaml` mappings against the actual repository paths on the registry
  (`skopeo list-tags` on the candidate repos) and correct the mapping (or
  re-mirror to the expected path) so they agree.
- **Prevention:** Generate ICSP/IDMS/ITMS exclusively from `oc-mirror`'s own
  output for a given mirror run rather than hand-editing mappings, so the
  mapping and the content it describes can never drift apart.

## FC-8 — Upgrade appears to "go backwards" (done counter decreases)

- **Trigger:** Normal CVO status reporting/reconciliation behavior,
  misread as a rollback.
- **Symptom:** `N of M done` shows e.g. `69/906` then later `68/906`.
- **Root cause:** The CVO status reflects the current reconciliation pass,
  not a monotonically increasing counter; "dropping status report from
  earlier in sync loop" is a normal log line, not an error.
- **Remediation:** None needed — verify via `status.history[].state` (should
  say `Partial` while in progress, not a rollback indicator) and the
  explicit condition messages instead of the raw counter.
- **Prevention:** Train responders to read `oc describe clusterversion
  version` conditions rather than eyeballing the numeric counter alone.
