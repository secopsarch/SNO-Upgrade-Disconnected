# 04 — Second SNO Cluster: Validate / Modify / Create API Resources

Goal: bring **SNO #2** to the same disconnected upgrade-ready state as SNO #1 (after lessons learned), then upgrade **without support escalation**.

Assume SNO #1 taught: **mirror content for the target z-stream is mandatory**; ICSP mapping alone is not enough.

---

## 1. Inventory differences first

| Item | SNO #1 (reference) | SNO #2 (fill in) |
|------|--------------------|------------------|
| API URL / kubeconfig | workstation default | |
| Node name | master01 | |
| Node IP | 192.168.50.10 | |
| Registry | registry.ocp4.example.com:8443 | shared? dedicated? |
| Current OCP | 4.18.6 | |
| ICSP names | image-policy, release-*, operator-* | |
| registry-config CM | present | |
| CatalogSource | gls-catalog-cs | |
| MetalLB / LVMS | installed | |
| Channel | was empty → stable-4.18 | |

If registry is **shared**, mirror `TO_VER` once and reuse. Still validate pulls **from SNO #2 node**.

---

## 2. Required API resources (parity checklist)

Create or verify each resource on SNO #2.

### 2.1 Image config + trusted CA

**Objects:**

- ConfigMap `openshift-config/registry-config`
- `image.config.openshift.io/cluster` → `spec.additionalTrustedCA.name: registry-config`

**Validate:**

```bash
oc get cm registry-config -n openshift-config -o yaml
oc get image.config.openshift.io/cluster -o yaml | sed -n '/additionalTrustedCA/,+5p'
```

**Create if missing:** use [api-resources/registry-config-configmap.yaml](api-resources/registry-config-configmap.yaml) (replace PEM data) and [api-resources/image-config-patch.yaml](api-resources/image-config-patch.yaml).

**Key rule:** data key must be `hostname..port` with **two dots** before port, e.g. `registry.ocp4.example.com..8443`.

### 2.2 ImageContentSourcePolicy (release)

Ensure both mappings exist (names may differ; content matters):

```yaml
# conceptual
source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
mirrors: [REGISTRY/openshift/release]

source: quay.io/openshift-release-dev/ocp-release
mirrors: [REGISTRY/openshift/release-images]  # and/or .../openshift/release per lab
```

Templates: [api-resources/icsp-release.yaml](api-resources/icsp-release.yaml)

**Validate applied on node:**

```bash
oc debug node/<NODE> -- chroot /host grep -A3 'ocp-v4.0-art-dev' /etc/containers/registries.conf
```

MCP may briefly update when ICSP changes — wait for Updated=True before upgrade.

### 2.3 ImageContentSourcePolicy (operators)

Template: [api-resources/icsp-operators.yaml](api-resources/icsp-operators.yaml)

At minimum include orgs you actually use (`lvms4`, `openshift4`, etc.).

### 2.4 CatalogSource + OperatorGroup + Subscriptions

Templates:

- [api-resources/catalogsource-gls.yaml](api-resources/catalogsource-gls.yaml)
- [api-resources/subscriptions-metallb-lvms.yaml](api-resources/subscriptions-metallb-lvms.yaml)

**Validate:**

```bash
oc get catalogsource -n openshift-marketplace
oc get pods -n openshift-marketplace
oc get sub,csv -n metallb-system
oc get sub,csv -n openshift-storage
```

### 2.5 Optional modern mirrors (IDMS)

If SNO #2 is greenfield and you prefer IDMS:

Template: [api-resources/idms-release.yaml](api-resources/idms-release.yaml)

Do **not** apply conflicting ICSP+IDMS without understanding precedence. For clone-of-SNO1, keep ICSP-only.

### 2.6 Pull secret (cluster)

Nodes need credentials for the **local** registry if Quay requires auth:

```bash
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq '.auths | keys'
```

Ensure `REGISTRY` appears. If missing, merge auth and apply (see script `docs/scripts/merge-pull-secret.sh`).

---

## 3. On-the-fly creation sequence (SNO #2)

```bash
export KUBECONFIG=/path/to/sno2/kubeconfig
export REGISTRY=registry.ocp4.example.com:8443
export NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')

# 1) CA + image config
oc apply -f docs/api-resources/registry-config-configmap.yaml
oc patch image.config.openshift.io/cluster --type=merge \
  -p '{"spec":{"additionalTrustedCA":{"name":"registry-config"}}}'

# 2) ICSP
oc apply -f docs/api-resources/icsp-release.yaml
oc apply -f docs/api-resources/icsp-operators.yaml
oc get mcp -w   # wait Updated=True

# 3) Pull secret merge if needed
# ./docs/scripts/merge-pull-secret.sh

# 4) Operators (if installing fresh)
oc apply -f docs/api-resources/catalogsource-gls.yaml
oc apply -f docs/api-resources/subscriptions-metallb-lvms.yaml

# 5) Prove registry from THIS node
oc debug node/$NODE -- chroot /host curl -I https://$REGISTRY/v2/

# 6) Prove target digests exist (shared or local mirror)
./docs/scripts/validate-mirror.sh $REGISTRY 4.18.52

# 7) Only then channel + upgrade (SOP Phases 2–4)
```

---

## 4. Diff SNO #1 vs SNO #2 configs

```bash
# On a jump host with both kubeconfigs
K1=/path/sno1/kubeconfig
K2=/path/sno2/kubeconfig

for r in imagecontentsourcepolicy imagedigestmirrorset catalogsource; do
  echo "===== $r ====="
  diff -u \
    <(oc --kubeconfig=$K1 get $r -A -o yaml | sed '/resourceVersion\|uid\|creationTimestamp\|managedFields/d') \
    <(oc --kubeconfig=$K2 get $r -A -o yaml | sed '/resourceVersion\|uid\|creationTimestamp\|managedFields/d') || true
done

diff -u \
  <(oc --kubeconfig=$K1 get cm registry-config -n openshift-config -o yaml | sed '/resourceVersion\|uid\|creationTimestamp\|managedFields/d') \
  <(oc --kubeconfig=$K2 get cm registry-config -n openshift-config -o yaml | sed '/resourceVersion\|uid\|creationTimestamp\|managedFields/d') || true
```

Reconcile any missing mirrors or CA material on SNO #2.

---

## 5. Upgrade SNO #2 safely (order)

1. Complete mirror of `TO_VER` into Quay (if not already from SNO #1 incident).  
2. Run `docs/scripts/validate-pre-upgrade.sh`.  
3. Run `docs/scripts/validate-mirror.sh`.  
4. etcd backup on SNO #2.  
5. Set channel → `oc adm upgrade --to=TO_VER`.  
6. Monitor; do not cordon.  
7. Post checklist.

---

## 6. If SNO #1 is still Partial / stuck

You may repair SNO #1 by mirroring content (same as Phase 0), **in parallel** prepare SNO #2 so it never starts upgrade without G3.

Do not clear ClusterVersion desired update on SNO #1 unless following an approved abort procedure; missing images + wait is the supported recovery once content lands.
