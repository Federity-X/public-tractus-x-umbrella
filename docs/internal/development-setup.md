# Development Setup — Customising Tractus-X Components and Testing with Umbrella

> **Audience**: Developers who want to modify the source code of any Tractus-X (or upstream EDC) component — add an extension, patch a bug, adjust a service — and test the result inside the umbrella Helm deployment on a local Kubernetes cluster.

> **Aligned with Tractus-X Release 25.12 (umbrella v3.15.6)**

---

## Table of Contents

1. [Mental Model](#1-mental-model)
2. [Prerequisites](#2-prerequisites)
3. [Repository Layout](#3-repository-layout)
4. [Local Kubernetes Cluster](#4-local-kubernetes-cluster)
5. [The Core Inner-Loop Pattern](#5-the-core-inner-loop-pattern)
6. [Per-Component Build Recipes](#6-per-component-build-recipes)
   - [6.1 tractusx-edc (EDC Connector)](#61-tractusx-edc-edc-connector)
   - [6.2 Identity Hub (eclipse-edc/IdentityHub)](#62-identity-hub-eclipse-edcidentityhub)
   - [6.3 SSI DIM Wallet Stub](#63-ssi-dim-wallet-stub)
   - [6.4 Portal (Frontend + Backend)](#64-portal-frontend--backend)
   - [6.5 BPDM](#65-bpdm)
   - [6.6 Digital Twin Registry](#66-digital-twin-registry)
   - [6.7 simple-data-backend (in this repo)](#67-simple-data-backend-in-this-repo)
   - [6.8 Keycloak (CentralIDP / SharedIDP)](#68-keycloak-centralidp--sharedidp)
7. [Overriding Images in the Umbrella Chart](#7-overriding-images-in-the-umbrella-chart)
8. [Fast Iteration Workflow](#8-fast-iteration-workflow)
9. [Remote Debugging (JDWP / Node Inspector)](#9-remote-debugging-jdwp--node-inspector)
10. [Writing & Plugging in a Custom EDC Extension](#10-writing--plugging-in-a-custom-edc-extension)
11. [Replacing the Wallet Stub with Real Identity Hub](#11-replacing-the-wallet-stub-with-real-identity-hub)
12. [Troubleshooting](#12-troubleshooting)
13. [Housekeeping & Tips](#13-housekeeping--tips)

---

## 1. Mental Model

Every component deployed by umbrella is ultimately a **Docker image** referenced by a sub-chart. To test your change you need to:

```
┌──────────────────┐   ┌────────────────┐   ┌─────────────────────┐   ┌───────────────────┐
│ 1. Edit source   │ → │ 2. Build       │ → │ 3. Make image       │ → │ 4. Override image │
│    (EDC, IdHub,  │   │    Docker      │   │    visible to the   │   │    in umbrella    │
│    Portal, …)    │   │    image       │   │    K8s cluster      │   │    values & apply │
└──────────────────┘   └────────────────┘   └─────────────────────┘   └───────────────────┘
```

Steps 3 and 4 are the same for every component. The only things that vary per component are *how to build* (gradle, maven, npm, go…) and *where in the values file to override the image*.

---

## 2. Prerequisites

| Tool | Minimum version | Purpose |
|------|---|---|
| Docker Desktop (or Docker Engine + buildx) | 24.x | Build images |
| kubectl | 1.28+ | Talk to the cluster |
| Helm | 3.14+ | Install the umbrella chart |
| Minikube (recommended) **or** kind | latest | Local Kubernetes |
| Git | any | Clone repos |
| JDK | **17** (EDC) / **21** (Identity Hub & Portal backend) | Build Java |
| Node.js | **20 LTS** | Build Portal frontend |
| Maven | 3.9+ | Build `simple-data-backend` and Portal backend |
| Go | 1.22+ | Some EDC build tools |
| Python | 3.11+ | Seeding scripts |
| `yq` / `jq` | any | YAML/JSON editing |

RAM budget: **≥ 12 GB free** for a full umbrella deployment; **≥ 6 GB** if you disable the portal/observability.

---

## 3. Repository Layout

Create a single workspace folder for everything:

```bash
mkdir -p ~/workspace && cd ~/workspace

# This repo (umbrella — where you deploy from)
git clone git@github.com:Federity-X/public-tractus-x-umbrella.git

# Upstream component repos (only clone what you plan to modify)
git clone https://github.com/eclipse-tractusx/tractusx-edc.git
git clone https://github.com/eclipse-edc/IdentityHub.git
git clone https://github.com/eclipse-tractusx/ssi-dim-wallet-stub.git
git clone https://github.com/eclipse-tractusx/portal-frontend.git
git clone https://github.com/eclipse-tractusx/portal-backend.git
git clone https://github.com/eclipse-tractusx/bpdm.git
git clone https://github.com/eclipse-tractusx/sldt-digital-twin-registry.git
```

Result:

```
~/workspace/
├── public-tractus-x-umbrella/           ← deploys
├── tractusx-edc/                        ← controlplane + dataplane + extensions
├── IdentityHub/                         ← upstream EDC Identity Hub
├── ssi-dim-wallet-stub/                 ← the stub wallet used by umbrella
├── portal-frontend/                     ← React app
├── portal-backend/                      ← .NET API
├── bpdm/                                ← Kotlin/Spring
└── sldt-digital-twin-registry/          ← Spring Boot
```

---

## 4. Local Kubernetes Cluster

### Option A — Minikube (matches existing umbrella docs)

```bash
minikube start --cpus=4 --memory=10gb --driver=docker
minikube addons enable ingress
minikube addons enable ingress-dns    # optional, see docs/user/linux/README.md

# Map umbrella hostnames to the cluster IP (required)
echo "$(minikube ip)    centralidp.tx.test sharedidp.tx.test portal.tx.test \
  portal-backend.tx.test ssi-dim-wallet-stub.tx.test dataconsumer-1-dataplane.tx.test \
  dataconsumer-1-controlplane.tx.test dataprovider-dataplane.tx.test \
  dataprovider-controlplane.tx.test dataprovider-submodelserver.tx.test \
  semantics.tx.test sdfactory.tx.test ssi-credential-issuer.tx.test" \
  | sudo tee -a /etc/hosts
```

**Critical step** — point your shell's Docker CLI at the minikube daemon so images are immediately usable in the cluster without a registry:

```bash
eval $(minikube docker-env)       # any `docker build` now goes to minikube's daemon
# To revert in this shell:        eval $(minikube docker-env -u)
```

### Option B — kind

```bash
kind create cluster --name umbrella --config=- <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - { containerPort: 80,  hostPort: 80  }
  - { containerPort: 443, hostPort: 443 }
EOF

# Install ingress-nginx for kind
kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml
```

With kind, **after each local build** you must push the image into the cluster:

```bash
kind load docker-image local/my-image:dev --name umbrella
```

### Verify

```bash
kubectl get nodes
kubectl get ingressclass
```

---

## 5. The Core Inner-Loop Pattern

Every component follows the same four-step rhythm. Memorise this — it applies whether you're rebuilding EDC, Portal, or anything else.

```bash
# 1. Build docker image (uses minikube's docker thanks to `eval $(minikube docker-env)`)
cd <component-repo>
<build-command>                                             # varies per component

# 2. Tag it under a predictable local name
docker tag <original-tag> local/<component>:dev

# 3. Override in umbrella values-dev.yaml (one-time edit, see §7)
#    image.repository: local/<component>
#    image.tag: dev
#    image.pullPolicy: Never

# 4. Trigger a rolling restart of just that deployment
kubectl rollout restart deployment -n umbrella umbrella-<component>
kubectl rollout status  deployment -n umbrella umbrella-<component>
kubectl logs -f         deployment/umbrella-<component> -n umbrella
```

Because `pullPolicy: Never` is set and the image tag is stable (`:dev`), Kubernetes re-uses whatever is currently in the local Docker daemon — so your rebuild-and-restart loop is ~10 seconds.

---

## 6. Per-Component Build Recipes

### 6.1 tractusx-edc (EDC Connector)

Produces **controlplane** and **dataplane** images used by `tractusx-connector` sub-chart inside `tx-data-provider`, `dataconsumerOne`, `dataconsumerTwo`.

```bash
cd ~/workspace/tractusx-edc

# Build everything and dockerize in one shot:
./gradlew dockerize

# Or build just one image:
./gradlew :edc-controlplane:edc-runtime-memory:dockerize
./gradlew :edc-dataplane:edc-dataplane-base:dockerize
```

Gradle produces images like:

```
tractusx/edc-controlplane-postgresql-hashicorp-vault:0.12.0-SNAPSHOT
tractusx/edc-dataplane-hashicorp-vault:0.12.0-SNAPSHOT
```

Retag:

```bash
docker tag tractusx/edc-controlplane-postgresql-hashicorp-vault:0.12.0-SNAPSHOT \
           local/edc-controlplane:dev
docker tag tractusx/edc-dataplane-hashicorp-vault:0.12.0-SNAPSHOT \
           local/edc-dataplane:dev
```

### 6.2 Identity Hub (eclipse-edc/IdentityHub)

```bash
cd ~/workspace/IdentityHub
./gradlew :launcher:identityhub:dockerize
docker tag identityhub:latest local/identity-hub:dev
```

Note: there is no umbrella sub-chart for Identity Hub today — see [§11](#11-replacing-the-wallet-stub-with-real-identity-hub).

### 6.3 SSI DIM Wallet Stub

```bash
cd ~/workspace/ssi-dim-wallet-stub
./mvnw clean package -DskipTests
docker build -t local/ssi-dim-wallet-stub:dev .
```

Override in umbrella:

```yaml
# values-dev.yaml
identity-and-trust-bundle:
  ssi-dim-wallet-stub:
    image:
      repository: local/ssi-dim-wallet-stub
      tag: dev
      pullPolicy: Never
```

### 6.4 Portal (Frontend + Backend)

**Frontend** (React):

```bash
cd ~/workspace/portal-frontend
yarn install
yarn build
docker build -f ./.conf/Dockerfile.prebuilt -t local/portal-frontend:dev .
```

**Backend** (.NET 8):

```bash
cd ~/workspace/portal-backend/src
dotnet publish portal/Portal.Service/Portal.Service.csproj -c Release -o ./out
docker build -t local/portal-backend-service:dev -f portal/Portal.Service/Dockerfile .
```

The Portal bundle is deployed by the **umbrella-infrastructure** chart via the umbrella's `values-adopter-portal.yaml`. Override with:

```yaml
portal:
  frontend:
    image:
      name: local/portal-frontend
      tag: dev
      pullPolicy: Never
  backend:
    service:
      image:
        name: local/portal-backend-service
        tag: dev
        pullPolicy: Never
```

### 6.5 BPDM

BPDM is multiple Spring Boot services (pool, gate, orchestrator, cleaning-service):

```bash
cd ~/workspace/bpdm
./gradlew :bpdm-pool:bootJar
./gradlew :bpdm-gate:bootJar
./gradlew :bpdm-orchestrator:bootJar

# Each service has its own Dockerfile under bpdm-<service>/
docker build -t local/bpdm-pool:dev        -f bpdm-pool/Dockerfile        bpdm-pool
docker build -t local/bpdm-gate:dev        -f bpdm-gate/Dockerfile        bpdm-gate
docker build -t local/bpdm-orchestrator:dev -f bpdm-orchestrator/Dockerfile bpdm-orchestrator
```

Override the images under `bpdm.*` in `values-adopter-data-exchange.yaml` or `values-dev.yaml`.

### 6.6 Digital Twin Registry

```bash
cd ~/workspace/sldt-digital-twin-registry
./mvnw clean package -DskipTests
cd backend
docker build -t local/digital-twin-registry:dev .
```

Override:

```yaml
tx-data-provider:
  digital-twin-registry:
    registry:
      image:
        registry: ""
        repository: local/digital-twin-registry
        tag: dev
        pullPolicy: Never
```

### 6.7 simple-data-backend (in this repo)

This one lives inside the umbrella repo itself:

```bash
cd ~/workspace/public-tractus-x-umbrella/simple-data-backend
./mvnw clean package
docker build -t local/simple-data-backend:dev .
```

Override in `charts/simple-data-backend/values.yaml` or via `values-dev.yaml`:

```yaml
tx-data-provider:
  simple-data-backend:
    image:
      repository: local/simple-data-backend
      tag: dev
      pullPolicy: Never
```

### 6.8 Keycloak (CentralIDP / SharedIDP)

Keycloak itself is usually left as-is (bitnami image). If you're customising **realms** — edit the JSON seed files under `charts/umbrella/centralidp/` or `charts/umbrella/sharedidp/` and the chart will re-import them on the next `helm upgrade`. No image rebuild needed.

---

## 7. Overriding Images in the Umbrella Chart

**Never edit committed `values*.yaml` files for dev experiments.** Instead, maintain a personal overlay and gitignore it:

1. Create `charts/umbrella/values-dev.yaml`:

   ```yaml
   # --- Data provider EDC ---
   tx-data-provider:
     tractusx-connector:
       controlplane:
         image:
           repository: local/edc-controlplane
           tag: dev
           pullPolicy: Never
       dataplane:
         image:
           repository: local/edc-dataplane
           tag: dev
           pullPolicy: Never
     digital-twin-registry:
       registry:
         image:
           repository: local/digital-twin-registry
           tag: dev
           pullPolicy: Never
     simple-data-backend:
       image:
         repository: local/simple-data-backend
         tag: dev
         pullPolicy: Never

   # --- Data consumer 1 ---
   dataconsumerOne:
     tractusx-connector:
       controlplane:
         image: { repository: local/edc-controlplane, tag: dev, pullPolicy: Never }
       dataplane:
         image: { repository: local/edc-dataplane,    tag: dev, pullPolicy: Never }

   # --- Data consumer 2 ---
   dataconsumerTwo:
     tractusx-connector:
       controlplane:
         image: { repository: local/edc-controlplane, tag: dev, pullPolicy: Never }
       dataplane:
         image: { repository: local/edc-dataplane,    tag: dev, pullPolicy: Never }

   # --- Wallet stub ---
   identity-and-trust-bundle:
     ssi-dim-wallet-stub:
       image:
         repository: local/ssi-dim-wallet-stub
         tag: dev
         pullPolicy: Never
   ```

2. Add it to `.gitignore`:

   ```bash
   echo "charts/umbrella/values-dev.yaml" >> .gitignore
   ```

3. Install/upgrade the umbrella with your overlay layered **on top of** the default values files:

   ```bash
   cd charts/umbrella
   helm dependency update            # only on first run or when sub-chart versions change

   helm upgrade --install umbrella . \
     -f values-adopter-data-exchange.yaml \
     -f values-dev.yaml \
     -n umbrella --create-namespace
   ```

> **Rule of thumb**: values files listed later override earlier ones. Keep `values-dev.yaml` last.

---

## 8. Fast Iteration Workflow

Typical cycle after the first deploy:

```bash
# 1. Switch your shell to minikube's docker daemon (once per shell)
eval $(minikube docker-env)

# 2. Rebuild the image
cd ~/workspace/tractusx-edc
./gradlew :edc-controlplane:edc-runtime-memory:dockerize
docker tag tractusx/edc-controlplane-postgresql-hashicorp-vault:0.12.0-SNAPSHOT \
           local/edc-controlplane:dev

# 3. Restart just that deployment — no helm upgrade needed
kubectl rollout restart -n umbrella deployment/umbrella-dataprovider-edc-controlplane
kubectl rollout status  -n umbrella deployment/umbrella-dataprovider-edc-controlplane

# 4. Tail logs
kubectl logs -f -n umbrella deployment/umbrella-dataprovider-edc-controlplane
```

The cycle takes roughly as long as the build itself (~10 s for K8s to roll once the image is ready).

### When you DO need `helm upgrade`

- Changed any values in `values-dev.yaml`
- Added/removed a sub-chart dependency
- Changed ConfigMap / Secret / Ingress content

---

## 9. Remote Debugging (JDWP / Node Inspector)

### Java components (EDC, Identity Hub, Portal backend, BPDM, DTR)

Add this to the container's env in `values-dev.yaml`:

```yaml
tx-data-provider:
  tractusx-connector:
    controlplane:
      env:
        JAVA_TOOL_OPTIONS: "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005"
      service:
        extraPorts:
          - name: jdwp
            port: 5005
            targetPort: 5005
```

Then:

```bash
kubectl port-forward -n umbrella svc/umbrella-dataprovider-edc-controlplane 5005:5005
```

Attach IntelliJ → **Run → Edit Configurations → + → Remote JVM Debug** → `localhost:5005`.

### Node.js (if customising a Node-based service)

```yaml
env:
  NODE_OPTIONS: "--inspect=0.0.0.0:9229"
```

`kubectl port-forward ... 9229:9229` and open `chrome://inspect`.

### .NET (Portal backend)

```bash
kubectl exec -it -n umbrella deploy/umbrella-portal-backend -- bash
# inside:  install vsdbg, attach from VS Code "Attach to Process" over kubectl exec
```

---

## 10. Writing & Plugging in a Custom EDC Extension

Two approaches — pick based on permanence of the change:

### 10a. Quick / Experimental — Overlay JAR

Build your extension as a standalone JAR, then layer it on top of the upstream image:

```
my-edc-extension/
├── build.gradle.kts
├── src/main/java/com/acme/MyExtension.java
└── src/main/resources/META-INF/services/
    └── org.eclipse.edc.spi.system.ServiceExtension
```

`Dockerfile`:

```dockerfile
FROM tractusx/edc-controlplane-postgresql-hashicorp-vault:0.12.0
COPY build/libs/my-edc-extension.jar /app/extensions/
```

Build & tag:

```bash
./gradlew build
docker build -t local/edc-controlplane:dev .
```

Because `/app/extensions` is scanned at startup, your extension is loaded without touching tractusx-edc sources.

### 10b. Upstream-style — Fork tractusx-edc

Add your module under `edc-extensions/my-extension/` in your fork, then add it as a dependency in the launcher module you're building (`edc-controlplane/edc-runtime-memory/build.gradle.kts` or the postgres variant). Re-run `./gradlew dockerize`.

### Per-extension config

Extension settings go into EDC env vars (prefix `EDC_`, `TX_`) and into the connector values:

```yaml
tx-data-provider:
  tractusx-connector:
    controlplane:
      env:
        EDC_MY_EXTENSION_FEATURE_FLAG: "true"
```

---

## 11. Replacing the Wallet Stub with Real Identity Hub

Current default: the umbrella deploys `ssi-dim-wallet-stub`. To test with a real Identity Hub:

1. **Disable the stub** in `values-dev.yaml`:

   ```yaml
   identity-and-trust-bundle:
     ssi-dim-wallet-stub:
       enabled: false
   ```

2. **Deploy Identity Hub separately** into the same namespace. The IdentityHub repo contains a Helm chart at `charts/identity-hub/` — point it at your `local/identity-hub:dev` image:

   ```bash
   helm install identity-hub ~/workspace/IdentityHub/charts/identity-hub \
     -n umbrella \
     --set image.repository=local/identity-hub \
     --set image.tag=dev \
     --set image.pullPolicy=Never
   ```

3. **Rewire EDC** — in `values-dev.yaml`, replace all `ssi-dim-wallet-stub.tx.test` URLs with your Identity Hub service hostname. Key settings (see `ECOSYSTEM-GUIDE.md` for the full list):

   ```yaml
   tx-data-provider:
     tractusx-connector:
       iatp:              # if still on old key
         sts:
           dim:
             url: http://identity-hub.umbrella.svc:7171/api/v1/dim
           oauth:
             token_url: http://identity-hub.umbrella.svc:8080/oauth/token
       controlplane:
         env:
           TX_IAM_IATP_CREDENTIALSERVICE_URL: http://identity-hub.umbrella.svc:7171/api
   ```

   (New keys — after PR #2684 rename — use `dcp:` and `sts.div` respectively.)

4. **Provision a ParticipantContext** for each BPN through Identity Hub's Identity API before starting the EDC.

See `ECOSYSTEM-GUIDE.md` — *"What Changes When Identity Hub Replaces the Stub"* — for the full integration walkthrough and config-key mapping.

---

## 12. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ErrImagePull` or `ImagePullBackOff` on your custom image | K8s trying to pull `:dev` from Docker Hub | Ensure `pullPolicy: Never` is set and you ran `eval $(minikube docker-env)` **in the same shell** as the `docker build` |
| Pod restarts don't pick up new code | Image tag unchanged, K8s cached old image | `kubectl rollout restart deployment/...` is required — a simple pod delete works too |
| `helm upgrade` fails with "cannot patch immutable field" | Changed a `selector` or PVC field | `helm uninstall umbrella -n umbrella && helm install umbrella ...` |
| EDC can't reach wallet stub | Missing `/etc/hosts` entries | Re-run the `echo "$(minikube ip)..." >> /etc/hosts` step |
| `DNS` fails inside cluster | Ingress-DNS addon not enabled | `minikube addons enable ingress-dns` (Linux: also configure `dnsmasq`) |
| Build OOM on gradle | JVM heap too small | Add `export GRADLE_OPTS="-Xmx4g"` |
| Minikube out of disk | Old images piling up | `minikube ssh -- docker system prune -af` |
| Port-forward keeps dropping | Pod churn | Wrap in a loop: `while true; do kubectl port-forward ...; done` |
| Your gradle build pulls wrong JDK | `JAVA_HOME` not set | `export JAVA_HOME=$(/usr/libexec/java_home -v 17)` (macOS) |

### Quickly inspect what's in the cluster's registry

```bash
minikube ssh -- docker images | grep local/
```

### Get real-time logs from all EDC pods

```bash
kubectl logs -f -n umbrella -l app.kubernetes.io/name=tractusx-connector --all-containers=true --max-log-requests=20
```

---

## 13. Housekeeping & Tips

- **Gitignore your overlays** — `values-dev.yaml`, any `local-*.yaml`.
- **Stable tags matter**. Use `:dev` everywhere rather than `:<sha>` or `:<timestamp>` — this keeps the `helm upgrade` idempotent while letting `rollout restart` pick up new layers.
- **Pin helm deps once**: `helm dependency update` writes `Chart.lock`. Only re-run it when a sub-chart `version:` changes.
- **Wipe state between schema changes**:
  ```bash
  kubectl delete pvc -n umbrella --all
  ```
- **Full teardown**:
  ```bash
  helm uninstall umbrella -n umbrella
  kubectl delete ns umbrella
  minikube ssh -- docker system prune -af   # reclaim disk
  ```
- **Two-consumer sanity test** — after any EDC change, run a contract negotiation between `dataconsumerOne` and `tx-data-provider` (see `docs/user/common/data-transfer-guide.md` if present). If the negotiation still completes end-to-end, you haven't broken the DCP/VP flow.
- **Use the existing `hack/helm-dependencies.bash`** to refresh all repo indexes at once.
- **Bring your own observability** — the umbrella chart already bundles Jaeger + Prometheus + Loki + Grafana. Enable under `values-adopter-data-exchange-observability.yaml` and tail your custom EDC traces in Jaeger at `http://jaeger.tx.test`.

---

## Appendix A — One-Page Cheat Sheet

```bash
# --- Once per machine ------------------------------------------------------
minikube start --cpus=4 --memory=10gb --driver=docker
minikube addons enable ingress
echo "$(minikube ip) centralidp.tx.test sharedidp.tx.test portal.tx.test ..." \
     | sudo tee -a /etc/hosts

# --- Once per shell --------------------------------------------------------
eval $(minikube docker-env)

# --- Build a component (EDC shown) ----------------------------------------
cd ~/workspace/tractusx-edc
./gradlew dockerize
docker tag tractusx/edc-controlplane-postgresql-hashicorp-vault:0.12.0-SNAPSHOT \
           local/edc-controlplane:dev

# --- First deploy ---------------------------------------------------------
cd ~/workspace/public-tractus-x-umbrella/charts/umbrella
helm dependency update
helm upgrade --install umbrella . \
  -f values-adopter-data-exchange.yaml \
  -f values-dev.yaml \
  -n umbrella --create-namespace

# --- Iterate --------------------------------------------------------------
./gradlew :edc-controlplane:edc-runtime-memory:dockerize
docker tag tractusx/edc-controlplane-postgresql-hashicorp-vault:0.12.0-SNAPSHOT \
           local/edc-controlplane:dev
kubectl rollout restart -n umbrella deploy/umbrella-dataprovider-edc-controlplane
kubectl logs -f         -n umbrella deploy/umbrella-dataprovider-edc-controlplane
```

---

*Document for BE-165 companion — Based on tractus-x-umbrella v3.15.6 (aligned with Tractus-X Release 25.12)*
