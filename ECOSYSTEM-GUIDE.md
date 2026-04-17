# Tractus-X Umbrella — Complete Ecosystem Guide

A step-by-step walkthrough of every layer in the Eclipse Tractus-X Umbrella, from high-level concepts down to individual configuration fields.

---

## Table of Contents

1. [What Is This?](#1-what-is-this)
2. [Key Concepts You Must Know First](#2-key-concepts-you-must-know-first)
3. [Architecture Overview](#3-architecture-overview)
4. [Layer 1 — The Umbrella Chart (Orchestrator)](#4-layer-1--the-umbrella-chart-orchestrator)
5. [Layer 2 — Capability Bundles](#5-layer-2--capability-bundles)
6. [Layer 3 — Individual Components Deep-Dive](#6-layer-3--individual-components-deep-dive)
7. [Layer 4 — Identity & Trust (How Authentication Works)](#7-layer-4--identity--trust-how-authentication-works)
8. [Layer 5 — Data Exchange (The Core Flow)](#8-layer-5--data-exchange-the-core-flow)
9. [Layer 6 — Test Data Seeding Pipeline](#9-layer-6--test-data-seeding-pipeline)
10. [Layer 7 — Secrets & Vault Management](#10-layer-7--secrets--vault-management)
11. [Layer 8 — Networking & DNS](#11-layer-8--networking--dns)
12. [How to Deploy (Step-by-Step)](#12-how-to-deploy-step-by-step)
13. [Configuration Patterns & Values Files](#13-configuration-patterns--values-files)
14. [The Simulated Supply Chain](#14-the-simulated-supply-chain)
15. [Glossary](#15-glossary)

---

## 1. What Is This?

**Catena-X** is a European automotive industry data ecosystem — a standardized network where car manufacturers, suppliers, and recyclers share data securely (parts traceability, quality alerts, carbon footprint, etc.).

**Eclipse Tractus-X** is the open-source reference implementation of Catena-X.

**This repository** (`tractus-x-umbrella`) is a **Helm umbrella chart** that deploys an entire simulated Catena-X dataspace onto a single Kubernetes cluster. It's used for:

- End-to-end integration testing
- Local development sandboxes
- Learning how the Catena-X ecosystem works
- Onboarding new participants

**In simple terms**: This is a "dataspace-in-a-box" — one `helm install` spins up ~20+ interconnected services that simulate an entire automotive supply chain sharing data.

---

## 2. Key Concepts You Must Know First

### BPN (Business Partner Number)
A unique identifier for every company in the Catena-X network. Format: `BPNL00000003AYRE`.
- `BPNL` = Legal entity
- `BPNS` = Site (physical location)

### DID (Decentralized Identifier)
A self-sovereign identity string. Format: `did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003AYRE`.
Every participant has a DID that maps to their BPN.

### EDC (Eclipse Dataspace Connector)
The software that handles **data sharing contracts**. It has two planes:
- **Control Plane** — Negotiates contracts, manages policies ("who can access what")
- **Data Plane** — Performs the actual data transfer after a contract is agreed

### IATP / DCP (Decentralized Claims Protocol)
The newer authentication method replacing centralized service accounts. Uses **Verifiable Credentials** and **DIDs** instead of traditional OAuth tokens between connectors.

### Digital Twin
A virtual representation of a physical asset (e.g., a car part). Stored in a **Digital Twin Registry (DTR)** and contains pointers to submodel data.

### Submodel
The actual data behind a digital twin — e.g., the manufacturing details, material composition, or serial number of a part.

---

## 3. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         UMBRELLA CHART (Orchestrator)                           │
│                                                                                 │
│  ┌─────────────────┐  ┌────────────────┐  ┌──────────────────────────────────┐  │
│  │   Portal Layer   │  │  IAM Layer     │  │        Discovery Layer           │  │
│  │                  │  │                │  │                                  │  │
│  │  Portal Frontend │  │ CentralIDP     │  │ BPN Discovery                    │  │
│  │  Portal Backend  │  │ (Keycloak)     │  │ Discovery Finder                 │  │
│  │  - Registration  │  │                │  │ BDRS Server (BPN↔DID resolver)   │  │
│  │  - Admin         │  │ SharedIDP      │  │                                  │  │
│  │  - Marketplace   │  │ (Keycloak)     │  └──────────────────────────────────┘  │
│  │  - Notification  │  │                │                                        │
│  └─────────────────┘  └────────────────┘                                        │
│                                                                                 │
│  ┌──────────────────────────────────────────────────────────────────────────┐    │
│  │                    Identity & Trust Layer                                │    │
│  │                                                                          │    │
│  │   SSI DIM Wallet Stub ──── Verifiable Credentials ──── DIDs             │    │
│  │   SSI Credential Issuer                                                  │    │
│  │   Self-Description Factory                                               │    │
│  └──────────────────────────────────────────────────────────────────────────┘    │
│                                                                                 │
│  ┌──────────────────────────────────────────────────────────────────────────┐    │
│  │                    Data Exchange Layer                                    │    │
│  │                                                                          │    │
│  │  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐            │    │
│  │  │  DATA PROVIDER   │ │ DATA CONSUMER 1 │ │ DATA CONSUMER 2 │            │    │
│  │  │  (BPN_OEM_A)     │ │ (BPN_OEM_C)     │ │ (BPN_OEM_B)     │            │    │
│  │  │                  │ │                  │ │                  │            │    │
│  │  │ ┌──────────────┐ │ │ ┌──────────────┐ │ │ ┌──────────────┐ │          │    │
│  │  │ │EDC Control   │ │ │ │EDC Control   │ │ │ │EDC Control   │ │          │    │
│  │  │ │Plane         │ │ │ │Plane         │ │ │ │Plane         │ │          │    │
│  │  │ ├──────────────┤ │ │ ├──────────────┤ │ │ ├──────────────┤ │          │    │
│  │  │ │EDC Data      │ │ │ │EDC Data      │ │ │ │EDC Data      │ │          │    │
│  │  │ │Plane         │ │ │ │Plane         │ │ │ │Plane         │ │          │    │
│  │  │ ├──────────────┤ │ │ ├──────────────┤ │ │ ├──────────────┤ │          │    │
│  │  │ │PostgreSQL    │ │ │ │PostgreSQL    │ │ │ │PostgreSQL    │ │          │    │
│  │  │ ├──────────────┤ │ │ ├──────────────┤ │ │ ├──────────────┤ │          │    │
│  │  │ │Vault         │ │ │ │Vault         │ │ │ │Vault         │ │          │    │
│  │  │ ├──────────────┤ │ │ └──────────────┘ │ │ └──────────────┘ │          │    │
│  │  │ │DTR (Registry)│ │ │                  │ │                  │            │    │
│  │  │ ├──────────────┤ │ │                  │ │                  │            │    │
│  │  │ │Submodel Srvr │ │ │                  │ │                  │            │    │
│  │  │ └──────────────┘ │ └──────────────────┘ └──────────────────┘            │    │
│  │  └─────────────────┘                                                      │    │
│  └──────────────────────────────────────────────────────────────────────────┘    │
│                                                                                 │
│  ┌──────────────────────────────────────────────────────────────────────────┐    │
│  │                    Business Partner Layer                                │    │
│  │    BPDM Pool ── BPDM Gate ── BPDM Orchestrator ── Cleaning Service      │    │
│  └──────────────────────────────────────────────────────────────────────────┘    │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────┐                        │
│  │  Observability (Optional)                           │                        │
│  │  Prometheus │ Grafana │ Loki │ Jaeger │ OTEL        │                        │
│  └─────────────────────────────────────────────────────┘                        │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Layer 1 — The Umbrella Chart (Orchestrator)

**Location**: `charts/umbrella/`

The umbrella chart is the **top-level orchestrator**. It doesn't contain application code — it's a Helm `Chart.yaml` with ~20 dependencies that it wires together.

### How it works

1. `Chart.yaml` lists every dependency with a `condition` flag:
   ```yaml
   - condition: portal.enabled    # Only deployed if portal.enabled=true
     name: portal
     version: 2.6.0
   ```

2. `values.yaml` (1600+ lines) is where **everything is configured**:
   - Which components are enabled/disabled
   - All hostnames (`*.tx.test`)
   - Database passwords
   - Keycloak realm settings
   - EDC connector identities (BPNs, DIDs)
   - Service account credentials
   - Test data seeding configuration

3. **Everything is disabled by default**. You enable what you need via values files.

### Dependency hierarchy

```
umbrella
├── portal (from Tractus-X registry)
├── centralidp (Keycloak, from Tractus-X registry)
├── sharedidp (Keycloak, from Tractus-X registry)
├── bpdm (from Tractus-X registry)
├── sdfactory (from Tractus-X registry)
├── ssi-credential-issuer (from Tractus-X registry)
├── semantic-hub (from Tractus-X registry)
├── bpndiscovery (from Tractus-X registry)
├── discoveryfinder (from Tractus-X registry)
├── bdrs-server-memory (from Tractus-X registry)
├── tx-data-provider (LOCAL — file://../tx-data-provider)
│   ├── dataspace-connector-bundle (LOCAL)
│   ├── digital-twin-bundle (LOCAL)
│   └── data-persistence-layer-bundle (LOCAL)
├── dataconsumerOne (alias of tx-data-provider, LOCAL)
├── dataconsumerTwo (alias of tx-data-provider, LOCAL)
├── identity-and-trust-bundle (LOCAL)
├── pgadmin4 (from runix registry)
├── opentelemetry-collector (from OTEL registry)
├── jaeger, prometheus, loki, grafana (from respective registries)
└── cert-manager (from Jetstack)
```

Key insight: `tx-data-provider` is used **3 times** with different aliases to create 1 provider + 2 consumers.

---

## 5. Layer 2 — Capability Bundles

Bundles are **reusable building blocks** that package related services. They can be deployed standalone or as sub-charts.

### Bundle 1: Dataspace Connector Bundle
**Location**: `charts/dataspace-connector-bundle/`

Packages everything needed for one EDC participant:
| Component | Purpose |
|-----------|---------|
| `tractusx-connector` (v0.11.2) | The EDC itself (control + data plane) |
| `postgresql` (v15.2.1) | Stores contracts, negotiations, transfer state |
| `vault` (v0.27.0) | HashiCorp Vault for keys, tokens, secrets |

### Bundle 2: Digital Twin Bundle
**Location**: `charts/digital-twin-bundle/`

| Component | Purpose |
|-----------|---------|
| `digital-twin-registry` | REST API for registering/querying digital twins |
| `postgresql` | Stores twin definitions and submodel descriptors |

### Bundle 3: Data Persistence Layer Bundle
**Location**: `charts/data-persistence-layer-bundle/`

| Component | Purpose |
|-----------|---------|
| `simple-data-backend` | Lightweight Spring Boot in-memory submodel server |

### Bundle 4: Identity & Trust Bundle
**Location**: `charts/identity-and-trust-bundle/`

| Component | Purpose |
|-----------|---------|
| `ssi-dim-wallet-stub` | Simulates a real SSI wallet — issues DIDs, VCs, handles IATP |
| `postgresql` | Stores wallet data |

### The `tx-data-provider` Chart — Glueing Bundles Together
**Location**: `charts/tx-data-provider/`

This chart **composes all three core bundles** into a complete participant:

```
tx-data-provider
├── dataspace-connector-bundle (EDC + Vault + PostgreSQL)
├── digital-twin-bundle (DTR + PostgreSQL)
└── data-persistence-layer-bundle (Simple Data Backend)
```

Plus adds **post-install hooks** for:
- Vault secret initialization
- Test data upload (JSON → EDC assets → DTR twins → Submodel data)

---

## 6. Layer 3 — Individual Components Deep-Dive

### 6.1 Portal (Frontend + Backend)
- **Frontend**: React app at `portal.tx.test` — company registration, app marketplace, admin console
- **Backend**: 6 microservice APIs behind `portal-backend.tx.test`:
  - `/api/registration` — Company onboarding workflow
  - `/api/administration` — Governance, connector management
  - `/api/apps` — App marketplace
  - `/api/services` — Service catalog
  - `/api/notification` — Notification system
  - `/api/provisioning` — IDP provisioning
- **Portal PostgreSQL**: Stores all portal data
- **Test data seeding**: 16 pre-seeded companies with addresses, BPNs, and connector URLs

### 6.2 CentralIDP (Keycloak)
- Central authentication server at `centralidp.tx.test`
- Hosts the `CX-Central` realm
- Contains **client registrations** for every service:
  - `Cl7-CX-BPDM` — Pool client
  - `Cl16-CX-BPDMGate` — Gate client
  - `Cl3-CX-Semantic` — Semantic Hub client
  - `Cl22-CX-BPND` — BPN Discovery client
  - `Cl21-CX-DF` — Discovery Finder client
  - etc.
- Contains **19 service accounts** (`sa-cl1-reg-2`, `sa-cl2-01`, ... `sa-cl25-cx-3`) used for service-to-service auth
- Contains **16 test EDC service accounts** (`satest01`-`satest16`) — one per simulated company
- Uses an **init container** (`umbrella-init-container:2.3.0-init`) for realm seeding

### 6.3 SharedIDP (Keycloak)
- Secondary Keycloak at `sharedidp.tx.test`
- Hosts the `CX-Operator` realm
- Main user: `cx-operator@tx.test` / `tractusx-umbr3lla!`
- Used for operator-level administration of the dataspace

### 6.4 SSI DIM Wallet Stub
- Simulates a **real SSI (Self-Sovereign Identity) wallet**
- At `ssi-dim-wallet-stub.tx.test`
- Provides:
  - **DID documents** for each BPN (`/BPNL00000003AYRE/.well-known/did.json`)
  - **OAuth token endpoint** (`/oauth/token`) — EDC connectors use this to get tokens
  - **STS endpoint** (`/api/sts`) — Secure Token Service for credential exchange
  - **Credential Service** (`/api`) — Issues and verifies Verifiable Credentials
  - **BPN directory** (`/api/v1/directory`) — In-memory BPN-to-DID resolution
  - **Status list** — Credential revocation checking
- Seeds wallets for all configured BPNs on startup
- The **operator** BPN (`BPNL00000003CRHK`) acts as the trusted issuer

### 6.5 BPDM (Business Partner Data Management)
Runs 4 interconnected services under `business-partners.tx.test`:
- **Pool** (`/pool`) — The authoritative "golden record" for business partners
- **Gate** (`/gate`) — API for companies to submit/update their business partner data
- **Orchestrator** (`/orchestrator`) — Coordinates the golden record process
- **Cleaning Service (Dummy)** — Basic data validation/normalization

Flow: Gate receives data → Orchestrator coordinates → Cleaning validates → Pool stores golden record

### 6.6 Discovery Services
| Service | URL | Purpose |
|---------|-----|---------|
| BPN Discovery | `semantics.tx.test/bpndiscovery` | Given a part number (OEN, WMI), find the BPN of the manufacturer |
| Discovery Finder | `semantics.tx.test/discoveryfinder` | Given a discovery type, find the discovery endpoint URL |

Discovery Finder registers BPN Discovery as an endpoint. Applications query Discovery Finder first to learn where to resolve BPNs.

### 6.7 BDRS Server (BPN→DID Resolution)
- In-memory server mapping BPNs to DIDs
- Seeded via post-install hook with all 17 BPN↔DID pairs
- EDC connectors query this to resolve a partner's DID from their BPN

### 6.8 Simple Data Backend
**Location**: `simple-data-backend/`
- Spring Boot 3.2.3 / Java 21
- In-memory key-value store for submodel data
- REST API: PUT data in, GET data out
- Used as the submodel server behind digital twins
- Runs at `dataprovider-submodelserver.tx.test`

### 6.9 Semantic Hub
- At `semantics.tx.test/hub`
- Manages semantic models (SAMM/AAS) using Apache Jena Fuseki (triple store)
- Services look up model definitions here

---

## 7. Layer 4 — Identity & Trust (How Authentication Works)

This is the most complex layer. There are **two authentication contexts**:

### Context A: Human/Service → Application (OAuth2/OIDC via Keycloak)
Traditional Keycloak authentication:
```
User/Service Account → CentralIDP (Keycloak) → JWT Token → Application API
```
Used by: Portal, BPDM, Discovery services, Semantic Hub

### Context B: EDC Connector → EDC Connector (IATP/DCP via SSI Wallet)
Decentralized authentication for data exchange:
```
Step 1: Consumer EDC asks its Wallet for a Verifiable Presentation
Step 2: Consumer EDC sends VP to Provider EDC
Step 3: Provider EDC verifies VP against trusted issuers
Step 4: Provider EDC checks BDRS for BPN↔DID mapping
Step 5: Contract negotiation proceeds
```

### Detailed IATP Flow

```
                    Consumer EDC                              Provider EDC
                         │                                         │
                         │ 1. Request VP from Wallet               │
                         ├─────────► SSI DIM Wallet Stub           │
                         │           (POST /api/sts)               │
                         │◄──────── VP Token                       │
                         │                                         │
                         │ 2. Send Catalog Request + VP            │
                         ├────────────────────────────────────────►│
                         │                                         │
                         │         3. Provider verifies VP          │
                         │         4. Checks trusted issuers list   │
                         │         5. Resolves BPN via BDRS/Wallet │
                         │         6. Checks policies               │
                         │                                         │
                         │◄──────── Catalog Response               │
                         │                                         │
                         │ 7. Negotiate Contract                    │
                         ├────────────────────────────────────────►│
                         │◄──────── Contract Agreement              │
                         │                                         │
                         │ 8. Initiate Transfer                     │
                         ├────────────────────────────────────────►│
                         │◄──────── Data via Data Plane             │
```

### Key Identity Configuration per EDC

Each EDC connector is configured with:
```yaml
participant:
  id: BPNL00000003AZQP            # Their BPN
iatp:
  id: did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003AZQP   # Their DID
  trustedIssuers:
    - did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003CRHK    # Operator DID
  sts:
    dim:
      url: http://ssi-dim-wallet-stub.tx.test/api/sts          # Where to get tokens
    oauth:
      token_url: http://ssi-dim-wallet-stub.tx.test/oauth/token
      client:
        id: BPNL00000003AZQP
        secret_alias: edc-wallet-secret                         # Stored in Vault
```

---

## 8. Layer 5 — Data Exchange (The Core Flow)

This is what the whole system exists for. Here's the complete end-to-end flow:

### Step 1: Data Provider Registers an Asset

The provider has:
- **Submodel data** stored in the Simple Data Backend
- **A digital twin** registered in the DTR
- **An EDC asset** pointing to the submodel data
- **A policy** defining who can access it
- **A contract definition** linking the asset to the policy

### Step 2: Consumer Discovers the Provider

```
Consumer → Discovery Finder: "Where can I resolve BPNs?"
         → BPN Discovery: "Who made part OEN-12345?"
         → BDRS: "What's the DID for BPNL00000003AYRE?"
         → DTR (via EDC): "What digital twins exist?"
```

### Step 3: Contract Negotiation

```
Consumer EDC ──[Catalog Request]──► Provider EDC
     (authenticated via IATP/VP)
Consumer EDC ──[Negotiate Contract]──► Provider EDC
Consumer EDC ◄──[Contract Agreement]── Provider EDC
```

### Step 4: Data Transfer

```
Consumer Data Plane ◄──[Submodel Data]── Provider Data Plane
     (using agreed contract as authorization)
```

### Endpoints per Participant

| Role | Control Plane | Data Plane | Management Auth Key |
|------|--------------|------------|---------------------|
| Data Provider (OEM A) | `dataprovider-controlplane.tx.test` | `dataprovider-dataplane.tx.test` | `TEST2` |
| Data Consumer 1 (OEM C) | `dataconsumer-1-controlplane.tx.test` | `dataconsumer-1-dataplane.tx.test` | `TEST1` |
| Data Consumer 2 (OEM B) | `dataconsumer-2-controlplane.tx.test` | `dataconsumer-2-dataplane.tx.test` | `TEST3` |

---

## 9. Layer 6 — Test Data Seeding Pipeline

Seeding happens automatically via Helm **post-install hooks** (Kubernetes Jobs that run after `helm install`).

### Seeding Order (by hook weight)

| Order | Hook Weight | Job | What it does |
|-------|-------------|-----|-------------|
| 1 | `-5` | Vault setup | Seeds each EDC Vault with keys, tokens, wallet secrets |
| 2 | `-5` | BDRS setup | Seeds BPN↔DID mappings into the BDRS server |
| 3 | `-4` | Testdata upload | Runs Python script to create EDC assets, policies, twins |
| — | (on startup) | Keycloak realm seeding | Init container creates realms, clients, service accounts |
| — | (on startup) | Portal migration seeding | Seeds 16 companies, addresses, connectors into Portal DB |
| — | (on startup) | Wallet seeding | SSI DIM Wallet creates DIDs for configured BPNs |

### Vault Setup (post-install-vault-setup.yaml)
For each EDC instance:
1. Writes `edc-wallet-secret` to Vault (used for IATP authentication)
2. Writes `tokenSignerPublicKey` and `tokenSignerPrivateKey` (RSA keypair for JWT signing)
3. Writes `tokenEncryptionAesKey` (AES key for encrypting tokens)

### Test Data Upload (post-install-job-upload-testdata.yaml)
1. Waits for EDC and DTR to be ready (retries every 10s for 10 min)
2. Runs `upload-data.sh` → calls `transform-and-upload.py`
3. The Python script:
   - Reads `Testdata_AsBuilt-combustion.json` (sample Bill-of-Materials data)
   - For each part: creates a submodel in the Simple Data Backend
   - Creates an EDC asset pointing to the submodel URL
   - Creates access and contract policies (BPN-restricted)
   - Creates a contract definition linking asset → policy
   - Creates a digital twin shell in the DTR with submodel descriptors

### Portal Test Data (configmap-portal-testdata-seeding.yaml)
Seeds into portal database:
- 16 companies with German cities (Munich, Berlin, Cologne, Paris, Rome)
- Each company has a BPN, connector URL, and connector name
- Companies represent: OEMs (A, B, C), Tier suppliers (A, B, C), Sub-tiers, Dismantlers, IRS test, Trace-X sites

---

## 10. Layer 7 — Secrets & Vault Management

### HashiCorp Vault per EDC
Each EDC participant gets its own Vault instance:
- `edc-dataprovider-vault` — for the data provider
- `edc-dataconsumer-1-vault` — for consumer 1
- `edc-dataconsumer-2-vault` — for consumer 2

Contents of each Vault:
```
secret/data/edc-wallet-secret       → The IATP client secret
secret/data/tokenSignerPublicKey    → RSA public key (PEM)
secret/data/tokenSignerPrivateKey   → RSA private key (PEM)
secret/data/tokenEncryptionAesKey   → AES symmetric key
```

### External Secrets (Optional)
For production-like setups, the chart supports **External Secrets Operator**:
- `vault-secretstore.yaml` — Defines connection to external Vault
- `vault-external-secrets.yaml` — Defines which secrets to sync
- `fake-secretstore.yaml` / `fake-external-secrets.yaml` — Test stubs

### Vault Secrets Setup Script (dataseeding/)
`vault-secrets-setup.py` is a standalone Python script for initializing Vault:
```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=root
python vault-secrets-setup.py --yaml-file vault-secrets.yaml --vault-path secret
```

The `vault-secrets.yaml` contains all secrets organized by service:
- Keycloak DB passwords
- Keycloak admin passwords
- All 19 service account secrets
- All 16 test EDC service account secrets
- Keycloak client secrets (MIW, BPDM, etc.)

---

## 11. Layer 8 — Networking & DNS

### The `.tx.test` Domain Convention
Every service runs under the `.tx.test` domain. This is a **non-routable** domain that must be resolved locally.

### Complete Hostname Map

| Hostname | Service | Port |
|----------|---------|------|
| `portal.tx.test` | Portal Frontend | 8080 |
| `portal-backend.tx.test` | Portal Backend APIs | 8080 |
| `centralidp.tx.test` | CentralIDP Keycloak | 8080 |
| `sharedidp.tx.test` | SharedIDP Keycloak | 8080 |
| `ssi-dim-wallet-stub.tx.test` | SSI Wallet | 8080 |
| `ssi-credential-issuer.tx.test` | Credential Issuer | 8080 |
| `sdfactory.tx.test` | Self-Description Factory | 8080 |
| `semantics.tx.test` | Semantic Hub + Discovery | 8080 |
| `business-partners.tx.test` | BPDM (Pool/Gate/Orchestrator) | 8080 |
| `bdrs-server.tx.test` | BPN↔DID Resolution | 8080 |
| `dataprovider-controlplane.tx.test` | Provider EDC Control Plane | — |
| `dataprovider-dataplane.tx.test` | Provider EDC Data Plane | — |
| `dataprovider-submodelserver.tx.test` | Provider Submodel Server | 8080 |
| `dataprovider-dtr.tx.test` | Provider Digital Twin Registry | 8080 |
| `dataconsumer-1-controlplane.tx.test` | Consumer 1 EDC Control Plane | — |
| `dataconsumer-1-dataplane.tx.test` | Consumer 1 EDC Data Plane | — |
| `dataconsumer-2-controlplane.tx.test` | Consumer 2 EDC Control Plane | — |
| `dataconsumer-2-dataplane.tx.test` | Consumer 2 EDC Data Plane | — |
| `pgadmin4.tx.test` | pgAdmin (DB GUI) | 80 |
| `smtp.tx.test` | SMTP mail server | 587 |

### Ingress Configuration
All services use **NGINX Ingress** with:
- CORS enabled (origin: `http://*.tx.test`)
- Regex-based URL rewriting for path-routed services
- TLS disabled by default (can be enabled with cert-manager)

---

## 12. How to Deploy (Step-by-Step)

### Prerequisites
- Docker Desktop or equivalent
- Minikube (recommended) or any Kubernetes cluster
- Helm 3.12+
- 4 CPU cores, 6 GB RAM minimum

### Step 1: Start Kubernetes Cluster
```bash
minikube start --cpus=4 --memory=6gb
```

### Step 2: Enable Ingress
```bash
minikube addons enable ingress
minikube addons enable ingress-dns
```

### Step 3: Configure DNS
Add to `/etc/hosts` (replace `<MINIKUBE_IP>` with output of `minikube ip`):
```
<MINIKUBE_IP>    centralidp.tx.test
<MINIKUBE_IP>    sharedidp.tx.test
<MINIKUBE_IP>    portal.tx.test
<MINIKUBE_IP>    portal-backend.tx.test
<MINIKUBE_IP>    ssi-dim-wallet-stub.tx.test
<MINIKUBE_IP>    dataprovider-controlplane.tx.test
<MINIKUBE_IP>    dataprovider-dataplane.tx.test
<MINIKUBE_IP>    dataconsumer-1-controlplane.tx.test
<MINIKUBE_IP>    dataconsumer-1-dataplane.tx.test
<MINIKUBE_IP>    bdrs-server.tx.test
<MINIKUBE_IP>    business-partners.tx.test
<MINIKUBE_IP>    semantics.tx.test
<MINIKUBE_IP>    pgadmin4.tx.test
```

On macOS, also install [Docker Mac Net Connect](https://github.com/chipmk/docker-mac-net-connect) for Docker-to-Minikube networking.

### Step 4: Add Helm Repositories & Update Dependencies
```bash
# From the repo root:
bash hack/helm-dependencies.bash
```

This script:
1. Adds all required Helm repos (tractusx, hashicorp, bitnami, etc.)
2. Updates all chart dependencies in the correct order (bundles first, then tx-data-provider, then umbrella)

### Step 5: Install the Chart

**Option A — Data Exchange only** (lightweight):
```bash
helm install umbrella charts/umbrella \
  -f charts/values-test-data-exchange.yaml \
  --namespace umbrella --create-namespace \
  --timeout 10m
```

**Option B — Full stack** (everything):
```bash
helm install umbrella charts/umbrella \
  --set portal.enabled=true \
  --set centralidp.enabled=true \
  --set sharedidp.enabled=true \
  --set tx-data-provider.enabled=true \
  --set dataconsumerOne.enabled=true \
  --set identity-and-trust-bundle.enabled=true \
  --set bdrs-server-memory.enabled=true \
  --set bpdm.enabled=true \
  --set bpndiscovery.enabled=true \
  --set discoveryfinder.enabled=true \
  --namespace umbrella --create-namespace \
  --timeout 15m
```

### Step 6: Wait for Post-Install Hooks
After `helm install`, Kubernetes jobs run automatically:
1. Vault initialization (writes keys to each Vault)
2. BDRS seeding (registers BPN↔DID mappings)
3. Test data upload (creates EDC assets, policies, twins)

Monitor progress:
```bash
kubectl get pods -n umbrella --watch
kubectl get jobs -n umbrella
```

### Step 7: Verify
```bash
# Check all pods are running
kubectl get pods -n umbrella

# Test Keycloak
curl http://centralidp.tx.test/auth/realms/CX-Central

# Test an EDC
curl -H "X-Api-Key: TEST2" http://dataprovider-controlplane.tx.test/management/v3/assets
```

---

## 13. Configuration Patterns & Values Files

### Pre-built Values Files

| File | Purpose | What's enabled |
|------|---------|---------------|
| `charts/umbrella/values.yaml` | Base defaults | Nothing (all `enabled: false`) |
| `charts/values-test-data-exchange.yaml` | Data exchange testing | EDC provider + consumers, Wallet, BDRS |
| `charts/values-test-iam-init-container-1.yaml` | IAM testing phase 1 | CentralIDP + SharedIDP |
| `charts/values-test-iam-init-container-2.yaml` | IAM testing phase 2 | CentralIDP + SharedIDP (continued) |
| `charts/values-test-shared-services-1.yaml` | Shared services phase 1 | Portal, IAM, BPDM |
| `charts/values-test-shared-services-2.yaml` | Shared services phase 2 | + Discovery, Semantic Hub |
| `charts/umbrella/values-adopter-data-exchange.yaml` | Adopter data exchange | Production-style config |
| `charts/umbrella/values-adopter-portal.yaml` | Adopter portal | Production-style portal |
| `charts/umbrella/values-tls.yaml` | TLS overlay | Cert-manager, TLS secrets |
| `charts/umbrella/values-external-secrets.yaml` | External secrets overlay | External Secrets Operator config |

### How to Layer Values
Helm values files are merged in order. Use multiple `-f` flags:
```bash
helm install umbrella charts/umbrella \
  -f charts/values-test-data-exchange.yaml \
  -f charts/umbrella/values-tls.yaml
```

### Common Configuration Patterns

**Enable a component**:
```yaml
portal:
  enabled: true
```

**Override a hostname**:
```yaml
portal:
  portalAddress: "https://portal.my-domain.com"
```

**Change a database password**:
```yaml
centralidp:
  keycloak:
    postgresql:
      auth:
        password: "my-secure-password"
```

**Add a new EDC participant** — use `tx-data-provider` as a dependency with an alias:
```yaml
# In Chart.yaml
- name: tx-data-provider
  alias: myNewParticipant
  version: 0.4.5
  repository: file://../tx-data-provider
  condition: myNewParticipant.enabled
```

---

## 14. The Simulated Supply Chain

The test data represents an automotive supply chain:

```
              ┌──────────────────┐
              │   OEM A (Provider)│ BPNL00000003AYRE
              │   (Manufacturer)  │ → Has digital twins + submodel data
              └────────┬─────────┘
                       │ supplies to
           ┌───────────┼───────────┐
           │           │           │
    ┌──────▼─────┐ ┌───▼──────┐ ┌──▼──────────┐
    │ OEM B      │ │ OEM C    │ │ IRS TEST    │
    │ Consumer 2 │ │Consumer 1│ │             │
    │ BPNL…AVTH │ │BPNL…AZQP│ │ BPNL…AWSS  │
    └────────────┘ └──────────┘ └─────────────┘

    Supporting supply chain:
    ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
    │ TIER A       │ │ TIER B       │ │ TIER C       │
    │ BPNL…B2OM   │ │ BPNL…B5MJ   │ │ BPNL…CSGV   │
    └──────┬───────┘ └──────┬───────┘ └──────────────┘
           │                │
    ┌──────▼───────┐ ┌──────▼───────┐ ┌──────────────┐
    │ SUB TIER A   │ │ SUB TIER B   │ │ SUB TIER C   │
    │ BPNL…B3NX   │ │ BPNL…AXS3   │ │ BPNL…BJTL   │
    └──────────────┘ └──────────────┘ └──────────────┘

    Specialized:
    ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
    │ DISMANTLER   │ │ TRACEX A     │ │ TRACEX B     │
    │ BPNL…B6LU   │ │ BPNL…CML1   │ │ BPNL…CNKC   │
    └──────────────┘ │ Site A:      │ │ Site A:      │
                     │ BPNS…08ZZ   │ │ BPNS…BDFH   │
                     └──────────────┘ └──────────────┘
    
    N-TIER A: BPNL…B0Q0
```

All 16+ companies have:
- A BPN assigned
- A DID in the SSI Wallet (`did:web:ssi-dim-wallet-stub.tx.test:<BPN>`)
- A service account in Keycloak (`satest01`-`satest16`)
- A BPN↔DID entry in the BDRS server
- A company record in the Portal database

Only the **Data Provider (OEM A)** has actual EDC infrastructure deployed with test data. The consumers (OEM B, OEM C) have EDC connectors but no pre-loaded data.

---

## 15. Glossary

| Term | Meaning |
|------|---------|
| **AAS** | Asset Administration Shell — standardized digital twin format |
| **BDRS** | BPN/DID Resolution Service — maps BPNs to DIDs |
| **BPN** | Business Partner Number — unique company identifier |
| **BPDM** | Business Partner Data Management — golden record system |
| **DCP** | Decentralized Claims Protocol (formerly IATP) |
| **DID** | Decentralized Identifier — self-sovereign identity identifier |
| **DTR** | Digital Twin Registry |
| **EDC** | Eclipse Dataspace Connector |
| **IATP** | Identity and Trust Protocol (now DCP) |
| **IDP** | Identity Provider (Keycloak) |
| **SAMM** | Semantic Aspect Meta Model |
| **SSI** | Self-Sovereign Identity |
| **STS** | Secure Token Service |
| **VC** | Verifiable Credential |
| **VP** | Verifiable Presentation |

---

*Generated from codebase analysis of Eclipse Tractus-X Umbrella v3.15.3*
