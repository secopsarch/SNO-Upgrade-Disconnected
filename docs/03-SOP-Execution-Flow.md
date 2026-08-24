# SOP — Upgrade Execution Flow (During the Upgrade)

Prerequisite: every gate in `docs/02-SOP-Preupgrade-Checklist.md` is green.

## Step 1 — Final go/no-go

- [ ] Re-run `oc get clusterversion,co,mcp,nodes` one last time immediately
      before starting. Nothing should have drifted since Gate 1.
- [ ] Confirm no other change window (network, storage, catalog) is active
      concurrently.
- [ ] Announce the maintenance window: on SNO, the API and console **will**
      be briefly unavailable during the mandatory reboot. This is expected,
      not a failure — see Constraint C2.

## Step 2 — Open the monitoring layout

Open five terminals (or five `tmux` panes) before issuing the upgrade
command, so you observe the very first status change instead of discovering
it minutes later:

| Pane | Command |
|---|---|
| 1 — CVO overall | `watch -n 5 'oc get clusterversion version'` |
| 2 — Operators | `watch -n 5 'oc get clusteroperators'` |
| 3 — Nodes/MCP | `watch -n 5 'oc get nodes; echo; oc get mcp'` |
| 4 — CVO logs | `oc logs -n openshift-cluster-version deployment/cluster-version-operator -f` |
| 5 — Cluster-wide events | `watch -n 5 "oc get events -A --sort-by='.lastTimestamp' | tail -40"` |

Or run `bash scripts/06-monitor-upgrade.sh` which tails the same signals in a
single consolidated loop suitable for a screen log/transcript.

## Step 3 — Issue the upgrade

Only use the version the cluster itself recommends (from Gate 4):

```bash
# If the channel isn't already set:
oc patch clusterversion version --type=merge -p '{"spec":{"channel":"stable-4.18"}}'

# Wait for the graph, then read the recommended version:
oc adm upgrade

# Start the upgrade using the *reported* version — do not hard-code one:
oc adm upgrade --to=<version-reported-by-oc-adm-upgrade>
```

- [ ] Confirm `oc get clusterversion version` immediately shows
      `PROGRESSING=True` with a `Working towards <target>: N of M done`
      message.

## Step 4 — Do **not** intervene on expected automation

The CVO and Machine Config Operator own node disruption end-to-end. **Do
not** run any of the following during a normal rollout:

```
oc adm cordon <node>
oc adm drain <node>
oc delete pod ...          # for CVO/operator-managed pods
oc rollout restart ...
```

Expected, non-alarming transient states:

- ClusterOperators flipping to `PROGRESSING=True` one at a time.
- The node showing `Ready,SchedulingDisabled` while the Machine Config
  Daemon applies the new RHCOS content.
- On SNO specifically: the node going `NotReady` and the API/console
  disappearing entirely during the reboot. This can last several minutes.
  Do not power-cycle, do not re-run `oc adm upgrade`, do not restart the CVO.

## Step 5 — Recognize a genuine stall vs. normal progress

| Signal | Normal | Investigate |
|---|---|---|
| `done/total` counter | Increases over time (sometimes appears to dip slightly as sync loop reconciles — not a rollback) | Frozen for > 15–20 minutes with an explicit error message |
| `oc get clusterversion` message | `Working towards <target>: N of M done, waiting on <component>` | `Unable to apply <target>: the workload <ns>/<name> has not yet successfully rolled out` (this is the exact message from cluster #1) |
| ClusterOperator | Temporarily `Progressing=True` | `Degraded=True` for an extended period, or `Available=False` |
| Node | `Ready,SchedulingDisabled` or briefly `NotReady` during reboot | `NotReady` for far longer than a normal reboot with no kubelet recovery |
| Pod | `Pending`/`ContainerCreating` briefly | `ImagePullBackOff`, `CrashLoopBackOff`, `Init:...BackOff` |

If you land in the "investigate" column, **stop watching and switch to**
`docs/05-Troubleshooting-Guide.md` — the exact `ImagePullBackOff` scenario
from cluster #1 is documented there with the full command sequence.

## Step 6 — If the upgrade stalls on a missing mirrored image

This is the scenario that happened on cluster #1. Do not treat it as an
operator bug — it is a mirror-content gap, and it is fixable without support:

1. Identify the failing pod/deployment/namespace from the CVO message.
2. `oc describe pod -n <ns> <pod>` → find the exact image digest in
   `ImagePullBackOff` events.
3. Confirm the digest is genuinely absent from the mirror (not a transient
   network blip): `scripts/07-diagnose-image-pull-failure.sh <digest>`.
4. If confirmed absent, mirror it: re-run Gate 5a
   (`scripts/04-mirror-missing-release-images.sh`) targeting the **same
   release digest** the CVO is currently applying (read it from
   `oc get clusterversion version -o jsonpath='{.status.desired.image}'`).
5. **Do not delete the stuck pod repeatedly hoping it retries faster** — the
   kubelet already retries with backoff, and CVO reconciles automatically
   once the image becomes pullable. Fix the mirror; let the existing backoff
   loop pick it up (usually within 1–5 minutes of the mirror becoming
   correct), or delete the pod **once** after the mirror is fixed to force
   an immediate retry instead of waiting out the backoff timer.
6. Resume monitoring from Step 2. Do not restart the CVO deployment.

## Step 7 — Completion criteria

- [ ] `oc get clusterversion version` shows the target version with
      `AVAILABLE=True`, `PROGRESSING=False`.
- [ ] `oc get clusterversion version -o jsonpath='{.status.history[0].state}'`
      returns `Completed` (not `Partial`).
- [ ] `oc get co` — zero operators degraded, all available.
- [ ] `oc get mcp` — all pools updated, not updating, not degraded.
- [ ] `oc get nodes` — all `Ready`.

Proceed to `docs/04-SOP-Postupgrade-Validation.md`.

## What to capture for the record (every run)

- Full transcript of the five monitoring panes (or the consolidated
  `06-monitor-upgrade.sh` log) from start to completion.
- `oc adm upgrade` output at the moment the target was chosen.
- `oc get clusterversion version -o yaml` at completion.
- Any stall episode: the exact error message, the digest involved, the fix
  applied, and the time-to-resolution.
