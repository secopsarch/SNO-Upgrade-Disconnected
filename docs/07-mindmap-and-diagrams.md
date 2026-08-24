# 07 — Mind Map, Execution Flow, Logical Diagrams

Render these Mermaid diagrams in any Mermaid-compatible viewer (GitHub, GitLab, many Markdown previews).

---

## 1. Mind map — disconnected SNO upgrade domain

```mermaid
mindmap
  root((SNO Disconnected Upgrade))
    Preconditions
      Cluster Health
      etcd Backup
      Operator CSV Health
      Maintenance Window
    Trust
      registry-config CM
      additionalTrustedCA
      certs.d on registry host
      Node CA bundle
    Mirror Map
      ICSP release
      ICSP operators
      registries.conf
      Optional IDMS
    Mirror Content
      release-images tag
      art-dev digests
      skopeo inspect
      crictl pull test
    Execute
      Set channel
      oc adm upgrade
      Watch CVO CO MCP
    SNO Behaviors
      Auto cordon drain
      API blip on reboot
      No manual drain
    Failure Modes
      manifest unknown
      unauthorized quay
      ImagePullBackOff
      TLS x509
    Second Cluster
      Diff APIs
      Shared Quay
      Validate from node2
```

---

## 2. Execution flow (happy path)

```mermaid
flowchart TD
  A[Start: SNO at FROM_VER] --> B{Cluster healthy?}
  B -->|No| B1[Remediate COs/MCP/pods] --> B
  B -->|Yes| C{Registry TLS from node = 401?}
  C -->|No| C1[Fix DNS/TLS/CA] --> C
  C -->|Yes| D{ICSP + registry-config present?}
  D -->|No| D1[Create/apply API resources] --> D
  D -->|Yes| E[Select TO_VER from docs/graph intent]
  E --> F[Mirror TO_VER into Quay ICSP paths]
  F --> G{Digest audit pass?}
  G -->|No| F
  G -->|Yes| H[etcd backup]
  H --> I[Set channel stable-4.18]
  I --> J{oc adm upgrade lists TO_VER?}
  J -->|No| J1[Resolve graph / local updates / pick listed target] --> J
  J -->|Yes| K[oc adm upgrade --to=TO_VER]
  K --> L[Monitor CVO / CO / Node / MCP]
  L --> M{Stuck ImagePull?}
  M -->|Yes| M1[Mirror missing digests] --> L
  M -->|No| N{Node reboot window?}
  N -->|Yes| N1[Wait for API / Ready] --> L
  N -->|No| O{Version=TO_VER and all green?}
  O -->|No| L
  O -->|Yes| P[Post checks + document]
  P --> Q[End]
```

---

## 3. Logical diagram — image pull path

```mermaid
flowchart LR
  subgraph Cluster
    CVO[CVO]
    DEP[config-operator Deployment]
    POD[Pod init: openshift-api]
    CRI[CRI-O / registries.conf]
  end
  subgraph Policy
    ICSP[ICSP]
  end
  subgraph Registries
    Q[quay.io art-dev]
    M[Local Quay REGISTRY/openshift/release]
  end
  CVO --> DEP --> POD --> CRI
  ICSP --> CRI
  CRI -->|try mirror first| M
  CRI -->|fallback| Q
  M -->|manifest unknown if not mirrored| X[ImagePullBackOff]
  Q -->|unauthorized disconnected| X
```

---

## 4. Logical diagram — trust asymmetry (incident warmup)

```mermaid
flowchart TB
  subgraph OpenShift
    CM[ConfigMap registry-config]
    IMG[image.config additionalTrustedCA]
    NODE[Node trusts registry]
  end
  subgraph RegistryHost
    P[Podman]
    CD["/etc/containers/certs.d empty"]
  end
  R[(registry:8443 TLS)]
  CM --> IMG --> NODE --> R
  P --> CD
  CD -.->|x509 fail| R
  FIX[Install CA to anchors + certs.d] --> P
  FIX --> R
```

---

## 5. Sequence — failure then recovery

```mermaid
sequenceDiagram
  participant Eng as Engineer
  participant CVO as CVO
  participant Kube as Kubelet
  participant Mir as Local Quay
  participant Q as quay.io
  Eng->>CVO: oc adm upgrade --to=4.18.52
  CVO->>CVO: Load payload / apply resources
  CVO->>Kube: Rollout config-operator
  Kube->>Mir: Pull art-dev@f015 via mirror path
  Mir-->>Kube: manifest unknown
  Kube->>Q: Pull art-dev@f015
  Q-->>Kube: unauthorized
  Kube-->>CVO: Deployment not Available
  Note over Eng,Mir: Engineer mirrors 4.18.52 completely
  Eng->>Mir: oc adm release mirror
  Kube->>Mir: Retry pull @f015
  Mir-->>Kube: 200 OK
  Kube-->>CVO: Pod Ready
  CVO->>CVO: Continue N/906 → Completed
```

---

## 6. Swimlane — before / during / after

```mermaid
flowchart LR
  subgraph BEFORE
    b1[Health]
    b2[Trust]
    b3[ICSP APIs]
    b4[Mirror content]
    b5[Operators]
    b6[etcd backup]
  end
  subgraph DURING
    d1[Set channel]
    d2[upgrade --to]
    d3[Watch layers]
    d4[Fix content if pull fails]
  end
  subgraph AFTER
    a1[Version Completed]
    a2[CO/MCP green]
    a3[CSV smoke]
    a4[Docs/handoff]
  end
  BEFORE --> DURING --> AFTER
```

---

## 7. Decision — SNO #2 readiness

```mermaid
flowchart TD
  S[SNO2 kickoff] --> D1{Shared registry with SNO1?}
  D1 -->|Yes| V1[Reuse mirrored TO_VER]
  D1 -->|No| V2[Stand up registry + mirror TO_VER]
  V1 --> P[Diff/apply CA ICSP Catalog Sub pull-secret]
  V2 --> P
  P --> T{Node pull digest OK?}
  T -->|No| P2[Fix map or content] --> T
  T -->|Yes| U[Backup + upgrade SOP]
```

---

## 8. ASCII mind map (printable)

```text
                     DISCONNECTED SNO UPGRADE
                                |
        +-----------------------+-----------------------+
        |                       |                       |
     PREP                    EXECUTE                  VERIFY
        |                       |                       |
   Health/Backup          Channel+Upgrade         CV Completed
   Trust/CA               Multi-watch             CO/MCP green
   ICSP APIs              No manual drain         Operators OK
   Mirror CONTENT         Content repair loop     Docs
        |
        +-- SNO2 parity (diff APIs, validate from its node)
```
