# Disconnected OpenShift SNO Upgrade — SOP & Runbook Toolkit

This repository documents, as a blind-followable Standard Operating Procedure
(SOP), a real disconnected **Single Node OpenShift (SNO) 4.18.6 → 4.18.52/53**
upgrade that stalled because the local Quay mirror registry did not yet
contain the target release's images (`Init:ImagePullBackOff` /
`manifest unknown` on `openshift-config-operator`, root-caused to a
stale/incomplete mirror). The goal is to let an operator run the same
upgrade on a **second SNO cluster**, end-to-end, without live support — by
validating every prerequisite (trust, mirror content, update graph, operator
compatibility, backups) *before* touching `ClusterVersion`.

Two independent documentation sets were produced against this same incident
and both are kept in this repository (neither was deleted so no work is
lost); they cover the same material with different structuring/emphasis, and
either one is self-contained. Pick whichever fits your workflow — the
content in the "Deep-dive kit" is generally more granular (gated checklist,
richer troubleshooting decision tree, rendered diagram images), while the
"Concise kit" is oriented toward compact, printable references.

## Kit 1 — Deep-dive SOP (`docs/00-…` through `docs/08-…`, `manifests/`, top-level `scripts/`)

| Path | Purpose |
|---|---|
| `docs/00-Executive-Summary.md` | One-page summary of the scenario, goal, and outcome |
| `docs/01-Constraints-Knowns-Unknowns.md` | Everything that is fixed, everything known from cluster #1, everything that must be re-discovered on cluster #2 |
| `docs/02-SOP-Preupgrade-Checklist.md` | Categorical pre-upgrade validation gates (must all be GREEN before touching `ClusterVersion`) |
| `docs/03-SOP-Execution-Flow.md` | The exact during-upgrade execution flow, monitoring commands, and go/no-go gates |
| `docs/04-SOP-Postupgrade-Validation.md` | Post-upgrade categorical validation and sign-off checklist |
| `docs/05-Troubleshooting-Guide.md` | Root-cause playbooks, including the exact `ImagePullBackOff` / `manifest unknown` scenario hit on cluster #1 |
| `docs/06-Mindmap-and-Diagrams.md` | Mind map, execution-flow flowchart, logical architecture diagram, and sequence diagram (Mermaid + ASCII + rendered images) |
| `docs/07-Best-Practices.md` | Operational best practices for disconnected OCP upgrades |
| `docs/08-Failure-Cases-and-Remediation.md` | Catalog of failure modes with symptoms, root cause, and fix |
| `docs/SNO-Upgrade-Master-SOP.md` | The full SOP concatenated into a single document (source for the Word export) |
| `SNO-Upgrade-Master-SOP.docx` | The same master SOP exported to Microsoft Word, with rendered diagram images embedded |
| `manifests/` | Ready-to-adapt OpenShift API resources (IDMS/ITMS/ICSP, `oc-mirror` v2 `ImageSetConfiguration`, CatalogSource, trust ConfigMap) |
| `scripts/` (top level) | Executable helper scripts that validate, discover, or create the above resources "on the fly" during the upgrade |
| `diagrams/` | Mermaid sources (`.mmd`) plus rendered `.svg`/`.png` for each diagram |

### How to use Kit 1 on the second SNO cluster

1. Read `docs/00-Executive-Summary.md` and `docs/01-Constraints-Knowns-Unknowns.md` first.
2. Run `scripts/00-preflight-check.sh` against cluster #2. Do not proceed past a red gate.
3. Follow `docs/02-SOP-Preupgrade-Checklist.md` top to bottom. Every checkbox maps to a script in `scripts/` or a manifest in `manifests/`.
4. When (and only when) every pre-upgrade gate is green, follow `docs/03-SOP-Execution-Flow.md` to start and babysit the upgrade.
5. If anything goes wrong, go straight to `docs/05-Troubleshooting-Guide.md` and `docs/08-Failure-Cases-and-Remediation.md` — do not improvise commands against a live CVO rollout.
6. After `oc get clusterversion` reports the target version with `Available=True/Progressing=False/Degraded=False`, complete `docs/04-SOP-Postupgrade-Validation.md` and sign off.

Regenerate the Word document for Kit 1 with:

```bash
pandoc docs/SNO-Upgrade-Master-SOP.md \
  -o SNO-Upgrade-Master-SOP.docx \
  --resource-path=.:docs:diagrams \
  --toc --toc-depth=3 \
  --metadata title="Disconnected OpenShift SNO Upgrade — SOP"
```

## Kit 2 — Concise SOP (`docs/00-overview-constraints.md` and siblings, `docs/api-resources/`, `docs/scripts/`)

| Path | Purpose |
|---|---|
| `docs/00-overview-constraints.md` | Constraints, knowns, unknowns, architecture |
| `docs/01-sop-upgrade.md` | Full step-by-step upgrade SOP |
| `docs/02-pre-during-post-checklist.md` | Categorical before / during / after checks |
| `docs/03-troubleshooting-guide.md` | Layered troubleshooting matrix |
| `docs/04-second-sno-cluster.md` | Replicate API resources on 2nd SNO |
| `docs/05-failure-cases.md` | Failure modes and remediations |
| `docs/06-best-practices.md` | Best practices for disconnected SNO upgrades |
| `docs/07-mindmap-and-diagrams.md` | Mind map, execution flow, logical diagrams |
| `docs/08-quick-reference.md` | One-page printable quick reference |
| `docs/api-resources/` | YAML templates (ICSP, registry-config, CatalogSource, etc.) |
| `docs/scripts/` | Validation scripts to run on the fly |
| `OCP-4.18-SNO-Disconnected-Upgrade-SOP.docx` | Word document for distribution |

Quick start for Kit 2: read `docs/00-overview-constraints.md` →
`docs/01-sop-upgrade.md` (do not skip Phase 0 mirror validation) →
`docs/02-pre-during-post-checklist.md` → `docs/04-second-sno-cluster.md` for
a second cluster → `docs/03-troubleshooting-guide.md` /
`docs/05-failure-cases.md` if stuck. Regenerate its Word document with
`python3 docs/scripts/generate-word-doc.py`.

## The one critical lesson both kits converge on

```text
Channel set + oc adm upgrade --to=X
        ≠
Target release images exist in the local mirror
```

The upgrade started and stalled at ~65–69/906 payload resources on
`openshift-config-operator` with `Init:ImagePullBackOff` because:

- The mirror had **4.18.6** content only (confirmed via `skopeo list-tags`).
- The 4.18.52 payload required digests such as
  `sha256:f015c4401dbbe...` (`cluster-config-api`) that were never mirrored.
- The mirror answered `manifest unknown`; the public Quay answered
  `unauthorized` (expected in a disconnected cluster).

**Fix / prevention:** fully mirror the target release's exact digest set
into the local registry (`oc-mirror` v2) and validate it **before** setting
the channel or issuing `oc adm upgrade`, then let the CVO's existing retry
loop resume automatically once the mirror is correct.

## Hosts used in the reference examples

| Role | Host | Notes |
|---|---|---|
| Workstation | `student@workstation` | `oc` / kubeconfig |
| SNO node | `master01` (192.168.50.10) | control-plane + worker |
| Registry | `registry.ocp4.example.com:8443` | nginx → Quay 3.8.12 |
| Utility (optional) | `lab@utility` | alternate kubeconfig path |

Adapt hostnames/IPs/versions for your second cluster — every script and
manifest in both kits uses placeholders (`<MIRROR_HOST>`, `<TARGET_VERSION>`,
etc.) precisely so nothing from cluster #1 is assumed to carry over
unverified.

## Scope and assumptions

- Target platform: Red Hat OpenShift Container Platform **4.18.x**, Single
  Node OpenShift (control-plane node also schedules workloads).
- Disconnected/mirrored registry: **Quay** (any version ≥ 3.8) reachable at a
  DNS name such as `registry.<cluster-domain>:8443`, fronted by nginx.
- Existing mirroring configuration may be **legacy ICSP** (as on cluster #1)
  or modern **IDMS/ITMS**. Both kits show how to work with either and how to
  migrate safely.
- Installed operators of interest: **MetalLB Operator** and **LVM Storage
  Operator**, installed via OLM from a custom `CatalogSource`
  (`gls-catalog-cs` in the reference environment).
- No internet egress from the cluster nodes. All images must come from the
  local mirror.

## License / disclaimer

Lab-derived operational documentation. Always cross-check target versions
against your organization's update recommendation/errata for the date of
execution. Do not force a digest that `oc adm upgrade` does not list unless
you intentionally use `--to-image` with a validated, fully mirrored payload.
