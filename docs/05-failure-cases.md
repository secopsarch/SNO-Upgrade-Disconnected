# 05 — Failure Cases and Remediations

| ID | Failure | Symptoms | Root cause | Remediation | Avoid next time |
|----|---------|----------|------------|-------------|-----------------|
| F01 | Registry Podman TLS failure | `x509: certificate signed by unknown authority` on `podman login` | Empty `/etc/containers/certs.d`; host trust missing CA while OpenShift has `registry-config` | Install intermediate+root CA to anchors + `certs.d/<registry>/ca.crt`; `update-ca-trust` | Include registry-host trust in build checklist |
| F02 | Upgrade without mirrored target | CVO Progressing; pod `Init:ImagePullBackOff`; Events `manifest unknown` + quay `unauthorized` | Quay only has old z-stream (e.g. 4.18.6) | `oc adm release mirror` / oc-mirror full `TO_VER`; verify digests; wait for retry | Gate upgrade on `validate-mirror.sh` |
| F03 | Wrong digest assumption | Assume tags imply digests | Digest-only mirror pulls | Always `skopeo inspect @sha256:...` | Spot-check payload digests |
| F04 | Manual cordon on SNO | Upgrade disrupted; workloads unschedulable | Operator intervened | Uncordon if safe; let MCO manage | Training: never manual drain mid-upgrade |
| F05 | Chasing empty `oc logs` | NotFound / no logs | Init never started (no Container ID) | Use `oc describe` Events | Troubleshoot matrix training |
| F06 | Pod name typo | `pods "..." not found` | Hash typo (`5467c84d` vs `5467c84d4d`) | Copy name from `oc get pods` | Use `-o name` |
| F07 | Edit registries.conf by hand | Drift / wiped on reconcile | File managed by MCO from ICSP | Fix ICSP/IDMS objects instead | Change control on mirror APIs only |
| F08 | Delete ImagePull pods in a loop | Same backoff forever | Content still missing | Fix mirror first | Content-before-retry rule |
| F09 | Force wrong version (e.g. 4.18.53) | Not in graph / unsupported path | Invented target | Use `oc adm upgrade` listing | Graph-first policy |
| F10 | Start upgrade with NoChannel confusion | No recommended updates | Channel empty by design for disconnected | Set channel or use local Cincinnati / `--to-image` with mirrored image | Document disconnected update method |
| F11 | ICSP missing on SNO #2 | Pulls hit quay.io → unauthorized | Resources not cloned | Apply ICSP + CA + pull-secret parity | Use `04-second-sno-cluster.md` |
| F12 | CA ConfigMap wrong key | TLS failures for ported registry | Key not `host..port` | Recreate key with double-dot | Template validation |
| F13 | MCP degraded after ICSP apply | UPDATING stuck | Render/apply issue | `oc describe mcp`; MCD logs; do not upgrade until clear | Change ICSP in maintenance |
| F14 | Operator CSV fails post-upgrade | MetalLB/LVMS degraded | Catalog/images not mirrored for new OCP | Mirror operator indexes/related images; fix Subscription channel | Include operators in mirror plan |
| F15 | Quay disk full mid-mirror | push errors; partial content | 152GB + new release | Expand volume; prune unused **only with care** | Capacity check in Phase 0 |
| F16 | Shared registry, different ICSP paths | manifest unknown even after mirror | Push path ≠ ICSP mirror path | Align `--to` with ICSP; or add mirror entry | Single naming standard |
| F17 | API gone during reboot | panic / unnecessary recovery | Normal SNO reboot | Wait; use out-of-band console | Communicate downtime |
| F18 | Abort by clearing desiredUpdate casually | Split brain / Partial history | Improvised rollback | Follow Red Hat abort guidance; prefer completing forward once mirrored | Plan forward-fix |
| F19 | Trust leaf cert only in Podman | Intermittent verify issues | Missing chain | Install issuing CA + root | openssl subject/issuer check |
| F20 | Confuse Podman local images with Quay content | False confidence | `podman images` ≠ Quay blobs | Inspect Quay tags/digests / API | Separate inventories |

---

## Deep dive: F02 (the primary incident)

### Chain

```text
oc adm upgrade --to=4.18.52
  → CVO loads payload sha256:dddcb2c76...
  → Applies resources until deployment openshift-config-operator
  → New RS wants init image art-dev@sha256:f015... (cluster-config-api)
  → registries.conf rewrites to REGISTRY/openshift/release@f015...
  → Quay: manifest unknown
  → Fallback quay.io: unauthorized
  → ImagePullBackOff
  → CVO: WorkloadNotAvailable (~65/906)
```

### Proof commands

```bash
skopeo list-tags docker://REGISTRY/openshift/release-images
# showed only 4.18.6-x86_64

skopeo inspect docker://REGISTRY/openshift/release@sha256:f015...
# manifest unknown

oc adm release info <4.18.52 image> | grep f015
# cluster-config-api
```

### Fix

Mirror entire 4.18.52 into `openshift/release` + `openshift/release-images`, re-verify digest, allow CVO to continue.

---

## Severity & response time guidance

| Severity | Example | Response |
|----------|---------|----------|
| Sev-1 | Cluster upgrading, control plane unstable, unknown cause | Stabilize monitoring; if ImagePull → mirror ASAP |
| Sev-2 | Upgrade stuck but API healthy, node Ready | Content repair; no reboot |
| Sev-3 | Pre-check failure before upgrade | Stop; fix gate |
| Sev-4 | Doc/process gap | Update SOP after change |
