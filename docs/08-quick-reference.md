# Quick Reference Card — Disconnected SNO Upgrade

Print this page; keep beside the console.

## Golden rule

**Mirror the target release digests into Quay before `oc adm upgrade`.**

## One-line diagnosis of the lab failure

```text
ImagePullBackOff + mirror "manifest unknown" + quay "unauthorized"
= target payload images not in local registry
```

## Do / Don't

| DO | DON'T |
|----|-------|
| Validate `/v2/` → 401 from node | Manual cordon/drain on SNO |
| `skopeo inspect @sha256:...` | Trust tags alone |
| Watch CVO + CO + MCP + node | Delete pods before fixing mirror |
| Set channel → use listed target | Invent 4.18.53 if not listed |
| Backup etcd | Hand-edit registries.conf |
| Fix CA on registry host for Podman | `--tls-verify=false` as steady state |

## Emergency command kit

```bash
oc get clusterversion version -o wide
oc get co; oc get mcp; oc get nodes
oc get pods -A | grep -E 'ImagePull|ErrImage|CrashLoop'
oc describe pod -n openshift-config-operator $(oc get pod -n openshift-config-operator -o name | head -1) | sed -n '/Events:/,$p'
skopeo inspect docker://registry.ocp4.example.com:8443/openshift/release@sha256:<DIGEST>
```

## Gates

1. Health green  
2. Trust OK  
3. ICSP present  
4. **Mirror content for TO_VER**  
5. Operators OK  
6. Backup done  
7. Channel + upgrade  

## SNO #2

Diff CA/ICSP/Catalog/Subscriptions/pull-secret → validate pull **from SNO2 node** → then upgrade.
