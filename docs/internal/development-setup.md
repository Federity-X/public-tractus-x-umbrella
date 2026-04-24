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
   - [6.2 Identity Hub (eclipse-tractusx/tractusx-identityhub)](#62-identity-hub-eclipse-tractusxtractusx-identityhub)
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
| JDK | **17** (tractusx-edc) / **21** (tractusx-identityhub, ssi-dim-wallet-stub, BPDM, DTR) | Build Java/Kotlin |
| Node.js | **20 LTS** | Build Portal frontend |
| Yarn | 1.22+ (classic) | Portal frontend package manager |
| .NET SDK | **9.0** | Build Portal backend |
| Maven | 3.9+ | Build `simple-data-backend`, BPDM, DTR |
| Gradle wrapper | shipped in repos | tractusx-edc, tractusx-identityhub, ssi-dim-wallet-stub |
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
git clone https://github.com/eclipse-tractusx/tractusx-identityhub.git
git clone https://github.com/eclipse-tractusx/ssi-dim-wallet-stub.git
git clone https://github.com/eclipse-tractusx/portal-frontend.git
git clone https://github.com/eclipse-tractusx/portal-backend.git
git clone https://github.com/eclipse-tractusx/portal.git             # Portal Helm chart lives here
git clone https://github.com/eclipse-tractusx/bpdm.git
git clone https://github.com/eclipse-tractusx/sldt-digital-twin-registry.git
```

Result:

```
~/workspace/
├── public-tractus-x-umbrella/           ← deploys
├── tractusx-edc/                        ← controlplane + dataplane + extensions (Java/Gradle)
├── tractusx-identityhub/                ← Tractus-X distribution of EDC Identity Hub + IssuerService (Java/Gradle, ships Helm charts)
├── ssi-dim-wallet-stub/                 ← the stub wallet used by umbrella (Java/Gradle)
├── portal-frontend/                     ← React app (TS/Vite/Yarn)
├── portal-backend/                      ← .NET 9.0 API (multiple services)
├── portal/                              ← Helm chart repo for Portal (frontend+backend)
├── bpdm/                                ← Kotlin/Spring (Maven) — pool/gate/orchestrator
└── sldt-digital-twin-registry/          ← Spring Boot (Maven)
```

> **Important**: The Portal **Helm chart is not in `portal-frontend` or `portal-backend`** — it lives in a separate `eclipse-tractusx/portal` repo (chart at `charts/portal/`). The umbrella consumes it as a sub-chart.

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

Gradle produces images tagged as **`<project-name>:<version>`** and **`<project-name>:latest`**, so the outputs are e.g.:

```
edc-controlplane-postgresql-hashicorp-vault:<version>
edc-controlplane-postgresql-hashicorp-vault:latest
edc-dataplane-hashicorp-vault:<version>
edc-dataplane-hashicorp-vault:latest
edc-runtime-memory:<version>
edc-runtime-memory:latest
```

> `<version>` comes from the gradle `version` property in `gradle.properties` (e.g. `0.12.0`, `0.13.0-SNAPSHOT`, `0.15.0-SNAPSHOT` depending on the branch you are on). The safest reference is the `:latest` tag produced by the same build.

Retag under a stable local name that your umbrella overlay references:

```bash
docker tag edc-controlplane-postgresql-hashicorp-vault:latest local/edc-controlplane:dev
docker tag edc-dataplane-hashicorp-vault:latest            local/edc-dataplane:dev
```

### 6.2 Identity Hub (eclipse-tractusx/tractusx-identityhub)

> In the Tractus-X ecosystem the Identity Hub / Issuer Service are consumed from **`eclipse-tractusx/tractusx-identityhub`** — a production-shaped distribution of the upstream `eclipse-edc/IdentityHub`, packaged with Helm charts, Postgres + HashiCorp Vault integration, and in-memory variants for dev/test. It uses the **same `:dockerize` Gradle task pattern** as tractusx-edc (`com.bmuschko.docker-remote-api`), so the build flow mirrors §6.1.

The repo ships **four runtimes** under `runtimes/` (each has its own `Dockerfile`):

| Runtime | Purpose |
|---|---|
| `identityhub`         | Production IdentityHub runtime (Postgres + Vault) |
| `identityhub-memory`  | In-memory IdentityHub runtime (demo/testing only) |
| `issuerservice`       | Production IssuerService runtime (Postgres + Vault) |
| `issuerservice-memory`| In-memory IssuerService runtime (demo/testing only) |

And **four matching Helm charts** under `charts/`:

| Chart | Notes |
|---|---|
| `tractusx-identityhub`         | Production chart — Postgres + Vault |
| `tractusx-identityhub-memory`  | Memory chart — ephemeral, dev/test only |
| `tractusx-issuerservice`       | Production IssuerService chart |
| `tractusx-issuerservice-memory`| Memory IssuerService chart |

Build images via the `:dockerize` task (builds shaded JAR + docker image in one step):

```bash
cd ~/workspace/tractusx-identityhub

# Build every runtime that has a Dockerfile (identityhub, identityhub-memory,
# issuerservice, issuerservice-memory)
./gradlew dockerize
```

Or build a single runtime:

```bash
./gradlew :runtimes:identityhub-memory:dockerize
```

Images produced (same convention as tractusx-edc — no `tractusx/` prefix, tagged with the gradle `version` and `latest`):

- `identityhub:<version>` / `identityhub:latest`
- `identityhub-memory:<version>` / `identityhub-memory:latest`
- `issuerservice:<version>` / `issuerservice:latest`
- `issuerservice-memory:<version>` / `issuerservice-memory:latest`

where `<version>` comes from `gradle.properties` (e.g. `0.2.0`).

Retag under a stable local name for the umbrella overlay:

```bash
docker tag identityhub-memory:latest   local/identity-hub:dev
docker tag issuerservice-memory:latest local/identity-hub-issuer:dev
```

**The umbrella's `identity-and-trust-bundle` currently depends only on `ssi-dim-wallet-stub`** — it does *not* pull in `tractusx-identityhub` yet. See [§11](#11-replacing-the-wallet-stub-with-real-identity-hub) for how to swap the stub for a real IdentityHub deployment using the charts above.

### 6.3 SSI DIM Wallet Stub

> Uses **Gradle** (not Maven). Has **two runtime variants**: `ssi-dim-wallet-stub-memory` (in-memory) and `ssi-dim-wallet-stub` (with Postgres). The umbrella uses the **in-memory** variant via the `identity-and-trust-bundle` sub-chart.

The `Dockerfile` at the repo root is multi-stage and runs the Gradle build itself (`FROM gradle:8.9-jdk21-alpine AS build`), so the simplest build is:

```bash
cd ~/workspace/ssi-dim-wallet-stub
docker build -t local/ssi-dim-wallet-stub:dev .
```

If you want to iterate on the JAR outside Docker (faster rebuilds while debugging), build locally first:

```bash
# In-memory runtime (what umbrella uses)
./gradlew :runtimes:ssi-dim-wallet-stub-memory:bootJar

# Persistent (Postgres) variant
./gradlew :runtimes:ssi-dim-wallet-stub:bootJar
```

> The repo ships its own Helm charts at `charts/ssi-dim-wallet-stub-memory/` and `charts/ssi-dim-wallet-stub/`. The umbrella pulls `ssi-dim-wallet-stub` from the `tractusx-dev` helm repo via `identity-and-trust-bundle`.

Override in umbrella (image keys live **under `wallet.*`** in the stub's chart — default repo is `tractusx/ssi-dim-wallet-stub-memory`):

```yaml
# values-dev.yaml
identity-and-trust-bundle:
  ssi-dim-wallet-stub:
    wallet:
      image:
        repository: local/ssi-dim-wallet-stub
        tag: dev
        pullPolicy: Never
```

> **Tip**: To run the stub as a bare JVM for debugging (no umbrella), use `./gradlew :runtimes:ssi-dim-wallet-stub-memory:bootRun` and hit Swagger at `http://localhost:8080/ui/swagger-ui/index.html`.

### 6.4 Portal (Frontend + Backend)

The Portal is three repos: `portal-frontend`, `portal-backend`, and `portal` (the Helm chart). The umbrella consumes the `portal` chart as a sub-chart.

**Frontend** (React + Vite + Yarn):

```bash
cd ~/workspace/portal-frontend
yarn install
yarn build

# Repo ships a Dockerfile under .conf/ — use it against the already-built bundle:
docker build -f ./.conf/Dockerfile.prebuilt -t local/portal-frontend:dev .
```

> For local dev without Docker, `yarn start` runs the app at `http://localhost:3001/`. But to test inside umbrella you need a container image.

**Backend** (.NET 9.0 — **ships MANY service images**, not one):

The portal-backend repo produces **separate Docker images for each microservice**. The main ones you'll touch:

| Service | Image name | Dockerfile |
|---|---|---|
| Registration Service       | `portal-registration-service`        | `docker/Dockerfile-registration-service` |
| Administration Service     | `portal-administration-service`      | `docker/Dockerfile-administration-service` |
| Marketplace App Service    | `portal-marketplace-app-service`     | `docker/Dockerfile-marketplace-app-service` |
| Services Service           | `portal-services-service`            | `docker/Dockerfile-services-service` |
| Notification Service       | `portal-notification-service`        | `docker/Dockerfile-notification-service` |
| Processes Worker           | `portal-processes-worker`            | `docker/Dockerfile-processes-worker` |
| Portal Migrations          | `portal-portal-migrations`           | `docker/Dockerfile-portal-migrations` |
| Provisioning Migrations    | `portal-provisioning-migrations`     | `docker/Dockerfile-provisioning-migrations` |
| Maintenance Service        | `portal-maintenance-service`         | `docker/Dockerfile-maintenance-service` |
| IAM Seeding                | `portal-iam-seeding`                 | `docker/Dockerfile-iam-seeding` |

```bash
cd ~/workspace/portal-backend
dotnet build src                                              # compile everything once

# Build only the service you changed, e.g. Registration:
docker build -t local/portal-registration-service:dev \
  -f docker/Dockerfile-registration-service .
```

**Override in umbrella** — the Portal sub-chart (from `eclipse-tractusx/portal`) splits into `frontend.*` and `backend.*` branches, and **each service uses a bespoke tag key** (not `image.tag`). Representative keys (check `charts/portal/values.yaml` in the portal repo for the exact list at the version you pin):

| Service             | Image key                                              | Tag key                                                                   |
| ------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------- |
| portal-frontend     | `portal.frontend.portal.image.name`                    | `portal.frontend.portal.image.portaltag`                                  |
| registration FE     | `portal.frontend.registration.image.name`              | `portal.frontend.registration.image.registrationtag`                      |
| portal-assets       | `portal.frontend.assets.image.name`                    | `portal.frontend.assets.image.assetstag`                                  |
| registration-service| `portal.backend.registration.image.name`               | `portal.backend.registration.image.registrationservicetag`                |
| administration-svc  | `portal.backend.administration.image.name`             | `portal.backend.administration.image.administrationservicetag`            |
| marketplace-app-svc | `portal.backend.appmarketplace.image.name`             | `portal.backend.appmarketplace.image.appmarketplaceservicetag`            |
| services-service    | `portal.backend.services.image.name`                   | `portal.backend.services.image.servicesservicetag`                        |
| notification-service| `portal.backend.notification.image.name`               | `portal.backend.notification.image.notificationservicetag`                |
| processes-worker    | `portal.backend.processesworker.image.name`            | `portal.backend.processesworker.image.processesworkertag`                 |
| portal-migrations   | `portal.backend.portalmigrations.image.name`           | `portal.backend.portalmigrations.image.portalmigrationstag`               |
| portal-maintenance  | `portal.backend.portalmaintenance.image.name`          | `portal.backend.portalmaintenance.image.portalmaintenancetag`             |
| provisioning-migrations | `portal.backend.provisioningmigrations.image.name` | `portal.backend.provisioningmigrations.image.provisioningmigrationstag`   |

Example overlay:

```yaml
# values-dev.yaml
portal:
  frontend:
    portal:
      image:
        name: local/portal-frontend
        portaltag: dev
        pullPolicy: Never
  backend:
    registration:
      image:
        name: local/portal-registration-service
        registrationservicetag: dev
        pullPolicy: Never
    administration:
      image:
        name: local/portal-administration-service
        administrationservicetag: dev
        pullPolicy: Never
    # … one entry per service you rebuilt
```

> **Always** verify the exact key names against `charts/portal/values.yaml` at the portal chart version the umbrella pulls (see `charts/umbrella/Chart.yaml` for the pinned version). Upstream occasionally renames tag fields.

### 6.5 BPDM

> BPDM is a **Maven multi-module** project (not Gradle) written in Kotlin/Spring Boot. Dockerfiles are centralised under `docker/<service>/`, not inside each module.

Modules:
- `bpdm-pool` — golden record of BPNs (authoritative store)
- `bpdm-gate` — participant-facing ingress
- `bpdm-orchestrator` — coordinates the golden-record process
- `bpdm-cleaning-service-dummy` — reference curation/enrichment service

Build:

```bash
cd ~/workspace/bpdm

# Build everything once (compiles all modules, produces the executable jars under
# bpdm-<service>/target/):
mvn clean package -DskipTests

# Or build a single service:
mvn -pl bpdm-pool -am clean package -DskipTests

# Dockerfiles live under docker/<service>/ and are invoked from repo root:
docker build -t local/bpdm-pool:dev         -f docker/pool/Dockerfile         .
docker build -t local/bpdm-gate:dev         -f docker/gate/Dockerfile         .
docker build -t local/bpdm-orchestrator:dev -f docker/orchestrator/Dockerfile .
docker build -t local/bpdm-cleaning-service-dummy:dev -f docker/cleaning-service-dummy/Dockerfile .
```

> The repo also ships a Helm chart at `charts/bpdm/` which is what the umbrella pulls from `tractusx-dev`.

**Override in umbrella** — BPDM sub-services are **nested under `bpdm:`** in the umbrella `values.yaml` (they are sub-charts of the BPDM parent chart, not siblings). So the override keys are:

```yaml
# values-dev.yaml
bpdm:
  bpdm-gate:
    image:
      registry: ""
      repository: local/bpdm-gate
      tag: dev
      pullPolicy: Never

  bpdm-pool:
    image: { registry: "", repository: local/bpdm-pool,         tag: dev, pullPolicy: Never }

  bpdm-orchestrator:
    image: { registry: "", repository: local/bpdm-orchestrator, tag: dev, pullPolicy: Never }

  bpdm-cleaning-service-dummy:
    image: { registry: "", repository: local/bpdm-cleaning-service-dummy, tag: dev, pullPolicy: Never }
```

### 6.6 Digital Twin Registry

> Spring Boot + Maven. Both the Maven build and the Dockerfile are driven from the **repo root** (the `backend/` folder is just the primary module).

```bash
cd ~/workspace/sldt-digital-twin-registry

# Compile all modules; runnable jar lands at
# backend/target/digital-twin-registry-backend-<version>.jar
mvn clean install -DskipTests

# Build the image from repo root (Dockerfile is at repo root):
docker build -t local/digital-twin-registry:dev .
```

Override — DTR is deployed by `tx-data-provider` **through the `digital-twin-bundle` sub-chart**, so the key path is:

```yaml
# values-dev.yaml
tx-data-provider:
  digital-twin-bundle:
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
mvn clean package
docker build -t local/simple-data-backend:dev .
```

Override in `charts/simple-data-backend/values.yaml` or via `values-dev.yaml`. `simple-data-backend` is deployed by `tx-data-provider` **through the `data-persistence-layer-bundle` sub-chart**:

```yaml
tx-data-provider:
  data-persistence-layer-bundle:
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
   # --- Data provider EDC + DTR + simple-data-backend (all under tx-data-provider) ---
   tx-data-provider:
     dataspace-connector-bundle:
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
     digital-twin-bundle:
       digital-twin-registry:
         registry:
           image:
             repository: local/digital-twin-registry
             tag: dev
             pullPolicy: Never
     data-persistence-layer-bundle:
       simple-data-backend:
         image:
           repository: local/simple-data-backend
           tag: dev
           pullPolicy: Never

   # --- Data consumer 1 (also wraps tractusx-connector via dataspace-connector-bundle) ---
   dataconsumerOne:
     dataspace-connector-bundle:
       tractusx-connector:
         controlplane:
           image: { repository: local/edc-controlplane, tag: dev, pullPolicy: Never }
         dataplane:
           image: { repository: local/edc-dataplane,    tag: dev, pullPolicy: Never }

   # --- Data consumer 2 ---
   dataconsumerTwo:
     dataspace-connector-bundle:
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

> **Why this nesting?** The `tx-data-provider` sub-chart (see `charts/tx-data-provider/Chart.yaml`) is itself an umbrella composed of three inner sub-charts: `dataspace-connector-bundle` (wraps `tractusx-connector`), `digital-twin-bundle` (wraps `digital-twin-registry`), and `data-persistence-layer-bundle` (wraps `simple-data-backend`). Because the `tx-data-provider` chart is aliased **three times** in the umbrella (`dataconsumerOne`, `tx-data-provider`, `dataconsumerTwo`), the same nested path applies under each alias.

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
docker tag edc-runtime-memory:latest local/edc-controlplane:dev

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
  dataspace-connector-bundle:
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
# Use the same version you'll run in the cluster (check your local build output)
FROM edc-controlplane-postgresql-hashicorp-vault:latest
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
  dataspace-connector-bundle:
    tractusx-connector:
      controlplane:
        env:
          EDC_MY_EXTENSION_FEATURE_FLAG: "true"
```

---

## 11. Replacing the Wallet Stub with Real Identity Hub

Current default: the umbrella deploys `ssi-dim-wallet-stub`. To test with a real Identity Hub:

> **Recommended path**: use the official **`eclipse-tractusx/tractusx-identityhub`** Helm charts (`tractusx-identityhub-memory` for quick dev, `tractusx-identityhub` for prod-shaped with Postgres + Vault). These are the Tractus-X-curated distribution of the upstream EDC IdentityHub — do **not** roll your own manifests unless you have a specific reason. The raw-manifest example below is kept only as a minimal fallback.

1. **Disable the stub** in `values-dev.yaml`:

   ```yaml
   identity-and-trust-bundle:
     ssi-dim-wallet-stub:
       enabled: false
   ```

2. **Deploy Identity Hub via the Tractus-X chart** (preferred). Add the repo and install the memory variant alongside the umbrella release:

   ```bash
   # Build the image locally (see §6.2) so it's available inside minikube
   eval $(minikube docker-env)
   (cd ~/workspace/tractusx-identityhub && ./gradlew :runtimes:identityhub-memory:dockerize)

   # Install from the chart in the cloned repo (or from the published Helm repo
   # once the Tractus-X release publishes images to docker.io)
   helm install identity-hub \
     ~/workspace/tractusx-identityhub/charts/tractusx-identityhub-memory \
     -n umbrella \
     --set image.repository=identityhub-memory \
     --set image.tag=latest \
     --set image.pullPolicy=Never
   ```

   For the production variant (`tractusx-identityhub`), also provide Postgres + Vault values per that chart's `values.yaml`.

   **Fallback — raw manifest** (only if you cannot use the chart). Port numbers below are **placeholders**; check the runtime's `resources/*.properties` under `runtimes/identityhub-memory/` and any env overrides:

   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: identity-hub
     namespace: umbrella
   spec:
     replicas: 1
     selector: { matchLabels: { app: identity-hub } }
     template:
       metadata: { labels: { app: identity-hub } }
       spec:
         containers:
         - name: identity-hub
           image: local/identity-hub:dev
           imagePullPolicy: Never
           env:
           # Port numbers are illustrative — set them to whatever the
           # launcher config expects.
           - { name: WEB_HTTP_PORT,              value: "8181" }
           - { name: WEB_HTTP_PRESENTATION_PORT, value: "10001" }
           - { name: WEB_HTTP_IDENTITY_PORT,     value: "8182" }
           - { name: WEB_HTTP_STS_PORT,          value: "9292" }
           ports:
           - { name: default,      containerPort: 8181 }
           - { name: presentation, containerPort: 10001 }
           - { name: identity,     containerPort: 8182 }
           - { name: sts,          containerPort: 9292 }
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: identity-hub
     namespace: umbrella
   spec:
     selector: { app: identity-hub }
     ports:
     - { name: default,      port: 8181,  targetPort: 8181 }
     - { name: presentation, port: 7171,  targetPort: 10001 }
     - { name: identity,     port: 8182,  targetPort: 8182 }
     - { name: sts,          port: 9292,  targetPort: 9292 }
   ```

   ```bash
   kubectl apply -f identity-hub.yaml
   ```

   For a production-shaped deployment, prefer the upstream `tractusx-identityhub` chart (with Postgres + Vault) over hand-rolled manifests.

3. **Rewire EDC** — in `values-dev.yaml`, replace all `ssi-dim-wallet-stub.tx.test` URLs with your Identity Hub service hostname. Key settings (see `ECOSYSTEM-GUIDE.md` for the full list):

   ```yaml
   tx-data-provider:
     dataspace-connector-bundle:
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
docker tag edc-controlplane-postgresql-hashicorp-vault:latest local/edc-controlplane:dev

# --- First deploy ---------------------------------------------------------
cd ~/workspace/public-tractus-x-umbrella/charts/umbrella
helm dependency update
helm upgrade --install umbrella . \
  -f values-adopter-data-exchange.yaml \
  -f values-dev.yaml \
  -n umbrella --create-namespace

# --- Iterate --------------------------------------------------------------
./gradlew :edc-controlplane:edc-runtime-memory:dockerize
docker tag edc-runtime-memory:latest local/edc-controlplane:dev
kubectl rollout restart -n umbrella deploy/umbrella-dataprovider-edc-controlplane
kubectl logs -f         -n umbrella deploy/umbrella-dataprovider-edc-controlplane
```

---

*Document for BE-165 companion — Based on tractus-x-umbrella v3.15.6 (aligned with Tractus-X Release 25.12)*
