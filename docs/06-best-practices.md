# 06 — Best Practices (Disconnected SNO Upgrades)

## 1. Content before channel

Treat the local mirror as part of the release train:

1. Pick candidate from documentation / errata.  
2. Mirror candidate completely.  
3. Audit digests.  
4. Set channel / start upgrade.

Never reverse this order on a production-like disconnected cluster.

## 2. Digest is the contract

Tags like `4.18.52-x86_64-cluster-config-operator` help humans; CRI-O pulls **digests**. Validation must be digest-based (`skopeo inspect @sha256:...`, `crictl pull @sha256:...`).

## 3. Preserve mirror path conventions

Match whatever ICSP already encodes:

| Source | Mirror repo (this lab) |
|--------|------------------------|
| `ocp-v4.0-art-dev` | `.../openshift/release` |
| `ocp-release` | `.../openshift/release-images` (and/or `.../openshift/release`) |

Changing paths mid-upgrade is high risk.

## 4. ICSP vs IDMS

- Existing ICSP on 4.18: **leave alone** during an active upgrade.  
- New clusters: prefer IDMS/ITMS via oc-mirror v2.  
- Migration: separate maintenance window, not during CVO Progressing=True.

## 5. SNO operational discipline

- No manual cordon/drain/reboot unless MCO failed and a documented break-glass procedure applies.  
- Expect API blackout during OS pivot.  
- Size maintenance windows for full node reboot + operator convergence.  
- etcd backup every time; understand restore limits on SNO.

## 6. Observability standard

Always run multi-layer watches (CVO + CO + node/MCP + CVO logs). Add registry access logs when disconnected.

## 7. Operators are part of the upgrade

MetalLB / LVMS (or others) need:

- Compatible channels  
- Mirrored catalog + related images  
- CSV health before and after  

## 8. Trust configuration in three places

1. OpenShift `registry-config` ConfigMap + `image.config` additionalTrustedCA  
2. Node trusted bundle (via that config)  
3. Admin hosts using Podman/skopeo (`certs.d` / system anchors)

All three can diverge — verify each.

## 9. Multi-cluster (SNO #1 / SNO #2)

- Prefer one shared Quay with identical repo layout.  
- Diff API resources between clusters before upgrade day.  
- Validate pulls from **each** node, not only from the registry host.  
- Upgrade one cluster at a time; keep the other as reference.

## 10. Change control artifacts

Keep:

- ICSP YAML backup  
- `registry-config` backup  
- Mirror command transcript + timestamp  
- `validate-mirror.sh` output  
- etcd backup location  
- Post-upgrade clusterversion history  

## 11. Don’ts (hard)

- Don’t use `--tls-verify=false` as the steady state.  
- Don’t force `--to-image` from the public digest without mirroring.  
- Don’t prune Quay sha256 directories manually.  
- Don’t assume `podman images` on the registry host equals Quay content.  
- Don’t invent z-stream numbers not shown by the update graph.

## 12. Interview / ops mental model

```text
Health → Trust → Mirror map → Mirror content → Operators → Backup → Channel → Upgrade → Verify
```

Skip any box and the failure mode is predictable (this lab skipped **Mirror content** after setting channel).
