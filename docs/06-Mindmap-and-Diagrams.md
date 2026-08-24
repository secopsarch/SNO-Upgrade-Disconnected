# Mind Map & Diagrams

All diagrams are provided twice: as **Mermaid** (renders natively on GitHub,
GitLab, VS Code, Obsidian, etc.) and as **ASCII** (renders anywhere,
including inside the exported Word document and plain terminals). The
Mermaid source files also live standalone under `diagrams/*.mmd`.

## 1. Mind map — the whole upgrade problem space

```mermaid
mindmap
  root((Disconnected SNO 4.18 Upgrade))
    Constraints
      No internet egress
      Single node = control-plane + worker
      Payload is an ordered DAG
      Digests, not tags
      Cincinnati graph decides valid hops
      SNO etcd restore is limited
    Trust
      OpenShift cluster trust (additionalTrustedCA)
      Registry host trust (Podman / containers/certs.d)
      TLS chain validation
    Mirror
      ICSP (legacy, still supported)
      IDMS / ITMS (recommended)
      oc-mirror v2 workflow
      Digest-level content validation
      Registry storage capacity
    Update graph
      Channel selection (stable-4.18)
      RetrievedUpdates condition
      Recommended vs conditional updates
      Never hard-code a target version
    Operators
      MetalLB Operator
      LVM Storage Operator
      CatalogSource / OLM
      Channel compatibility with target OCP
    Execution
      Baseline health gate
      Monitoring layout
      Expected automation (cordon/drain/reboot)
      Stall recognition
    Failure modes
      Cert/trust failure
      Missing mirrored image
      Operator incompatibility
      Node reboot exceeds window
      Storage exhaustion
    Validation
      ClusterVersion Completed
      ClusterOperators healthy
      MCP updated
      Operators Succeeded
      Post-upgrade backup
```

![Mind map of the disconnected SNO upgrade problem space](../diagrams/mindmap.png)

### ASCII equivalent

```
                              Disconnected SNO 4.18 Upgrade
                                          |
     -------------------------------------------------------------------------
     |            |            |            |            |          |       |
Constraints    Trust        Mirror      UpdateGraph   Operators  Execution Validation
  |               |            |            |            |          |       |
 no egress    cluster trust  ICSP/IDMS    channel      MetalLB   baseline  CVO=Completed
 SNO=1 node   host trust     oc-mirror    RetrievedUpd  LVM       monitor   CO healthy
 ordered DAG  TLS chain      digest check never-hardcode CatalogSrc expected  MCP updated
 digest pin                  storage cap  target ver    channel   automation ops Succeeded
 graph hops                                             compat    stall-detect backup
 SNO restore
 limited
```

## 2. Execution flow (flowchart)

```mermaid
flowchart TD
    A[Start: Cluster #2 identified for upgrade] --> B{Gate 0-1\nAccess + Baseline healthy?}
    B -- No --> B1[Fix baseline issues\nDo not proceed]
    B1 --> B
    B -- Yes --> C{Gate 2\nRegistry/Podman trust OK?}
    C -- No --> C1[Extract CA from registry-config\nInstall in ca-trust + certs.d]
    C1 --> C
    C -- Yes --> D{Gate 3\nMirror config inventoried?}
    D -- No --> D1[oc get icsp/idms/itms -o yaml\nDecide ICSP-vs-IDMS strategy]
    D1 --> D
    D -- Yes --> E{Gate 4\nChannel set + graph retrieved?}
    E -- No --> E1[Patch spec.channel\nWait RetrievedUpdates=True]
    E1 --> E
    E -- Yes --> F{Gate 5\nMirror content matches\ntarget digest set?}
    F -- No --> F1[Gate 5a: oc-mirror v2\nmirror target release + operators]
    F1 --> F
    F -- Yes --> G{Gate 6\nOperators compatible\nwith target OCP?}
    G -- No --> G1[Update operator channel /\naccept documented gap / hold]
    G1 --> G
    G -- Yes --> H{Gate 7\nFresh etcd backup taken?}
    H -- No --> H1[Run cluster-backup.sh\nCopy off-node]
    H1 --> H
    H -- Yes --> I[Open 5-pane monitoring layout]
    I --> J[oc adm upgrade --to=<graph-recommended-version>]
    J --> K{Progressing normally?}
    K -- Yes --> L{Reached target,\nAvailable/!Progressing/!Degraded?}
    K -- No / stalled --> M[Troubleshooting Guide\nSection 3 decision tree]
    M --> N{Root cause = missing\nmirrored image?}
    N -- Yes --> O[Mirror missing digest\nvia oc-mirror, let CVO resume]
    O --> K
    N -- No --> P[Follow matching playbook\nin Troubleshooting Guide]
    P --> K
    L -- No --> M
    L -- Yes --> Q[Post-Upgrade Validation\nCategories A-E]
    Q --> R[Sign-off + archive\nmirror inventory + backups]
    R --> S[Done]
```

![Execution flow flowchart for the pre-upgrade gates and upgrade rollout](../diagrams/execution-flow.png)

### ASCII equivalent (condensed)

```
[Gate 0-1: access+baseline] --fail--> fix, loop back
        | pass
[Gate 2: registry/host trust] --fail--> extract CA, install, loop back
        | pass
[Gate 3: mirror inventory] --fail--> classify ICSP/IDMS, loop back
        | pass
[Gate 4: channel + graph] --fail--> set channel, wait, loop back
        | pass
[Gate 5: mirror content == target digests] --fail--> Gate5a oc-mirror, loop back
        | pass
[Gate 6: operator compatibility] --fail--> update/accept/hold, loop back
        | pass
[Gate 7: fresh etcd backup] --fail--> take backup, loop back
        | pass
[Open monitoring] -> [oc adm upgrade --to=<recommended>]
        |
   progressing? --stalled--> Troubleshooting decision tree
        |                          |
        |                    missing image? --yes--> mirror it, resume
   reached target? --no--> back to troubleshooting
        | yes
[Post-upgrade validation A-E] -> [Sign-off] -> DONE
```

## 3. Logical / architecture diagram — disconnected mirror path

```mermaid
flowchart LR
    subgraph WS[Workstation]
      OC[oc / oc-mirror / skopeo]
    end
    subgraph SNO[SNO Cluster - master01]
      CVO[Cluster Version Operator]
      KUBELET[kubelet / CRI-O]
      MIRRORCFG["/etc/containers/registries.conf\n(rendered from ICSP/IDMS/ITMS)"]
      CVO --> KUBELET
      KUBELET --> MIRRORCFG
    end
    subgraph REGHOST[Registry Host]
      NGINX[nginx :8443]
      QUAY[Quay 3.8.x]
      STORAGE[(Quay blob storage\nsha256/ tree)]
      CERTSD["/etc/containers/certs.d/<host>:8443/ca.crt"]
      CATRUST["/etc/pki/ca-trust (system trust)"]
      NGINX --> QUAY
      QUAY --> STORAGE
    end
    UPSTREAM["quay.io / registry.redhat.io\n(unreachable from cluster nodes)"]

    OC -- "podman/skopeo login,\noc-mirror push" --> NGINX
    MIRRORCFG -- "pull-from-mirror = digest-only" --> NGINX
    KUBELET -. "direct pull attempt\n(fails: unauthorized, disconnected)" .-> UPSTREAM
    OC -. "reference source images\n(only reachable when\nstaging the mirror)" .-> UPSTREAM
    CERTSD -.-> NGINX
    CATRUST -.-> NGINX
```

![Logical architecture of the disconnected mirror path](../diagrams/logical-architecture.png)

### ASCII equivalent

```
 Workstation                     Registry Host                          (unreachable)
+-----------------+   login/    +--------------------------+   images   +----------------+
| oc / oc-mirror / |--push----->| nginx:8443 -> Quay 3.8.x  |<-- staged--| quay.io /       |
| skopeo            |           |   |                        |  from    | registry.redhat |
+-----------------+             |   v                        |  here    | .io             |
                                 | blob storage (sha256/*)   |          +----------------+
                                 | certs.d/ca.crt (Podman)   |
                                 | /etc/pki/ca-trust (system)|
                                 +--------------------------+
                                            ^
                                            | pull-from-mirror = digest-only
                                            |
                              +-------------------------------+
                              | SNO node (master01)            |
                              | CVO -> kubelet/CRI-O           |
                              | registries.conf (rendered      |
                              |   from ICSP / IDMS / ITMS)     |
                              +-------------------------------+
```

## 4. Sequence diagram — image pull during CVO rollout (success vs. failure path)

```mermaid
sequenceDiagram
    participant CVO as Cluster Version Operator
    participant KUBE as kubelet / CRI-O (node)
    participant MIRROR as Mirror (Quay)
    participant PUB as quay.io (public, unreachable)

    CVO->>KUBE: Apply Deployment referencing image@sha256:<digest>
    KUBE->>MIRROR: Pull <mapped-repo>@sha256:<digest>
    alt Digest present in mirror
        MIRROR-->>KUBE: 200 OK (manifest + blobs)
        KUBE-->>CVO: Container starts, Deployment becomes Available
        CVO->>CVO: Advance to next payload resource (N+1 of M)
    else Digest missing in mirror
        MIRROR-->>KUBE: 404 manifest unknown
        KUBE->>PUB: Fallback attempt to public registry
        PUB-->>KUBE: 401 unauthorized (disconnected cluster)
        KUBE-->>CVO: Init:ImagePullBackOff (retries with backoff)
        CVO->>CVO: "Unable to apply <ver>: workload not rolled out"
        Note over CVO,MIRROR: Operator mirrors the missing digest (Gate 5a)
        MIRROR-->>MIRROR: oc-mirror pushes exact digest content
        KUBE->>MIRROR: Retry pull (backoff timer or forced by pod delete)
        MIRROR-->>KUBE: 200 OK
        KUBE-->>CVO: Deployment becomes Available, rollout resumes
    end
```

![Sequence diagram of an image pull during CVO rollout, success vs. failure path](../diagrams/sequence-image-pull.png)

## Notes on rendering these diagrams

- GitHub, GitLab, Obsidian, and recent VS Code render Mermaid fenced blocks
  automatically.
- To render standalone images (PNG/SVG) for a slide deck, use
  [`@mermaid-js/mermaid-cli`](https://github.com/mermaid-js/mermaid-cli):

  ```bash
  npx -y @mermaid-js/mermaid-cli -i diagrams/execution-flow.mmd -o diagrams/execution-flow.svg
  ```
- The `.mmd` sources for each diagram above are saved individually under
  `diagrams/` for exactly this purpose.
