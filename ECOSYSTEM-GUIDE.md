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

> **This guide is the structural overview.** For the runtime deep-dive — *who talks to whom*, the DCP round-trips (STS → presentation → verify → BDRS → transfer → data pull), and how a dataspace is provisioned and operated — see the companion **[Dataspace Runtime & Component Communication](docs/common/architecture/dataspace-runtime-and-communication.md)**.

---

## 2. Key Concepts You Must Know First

### BPN (Business Partner Number)
A unique identifier for every company in the Catena-X network. Format: `BPNL00000003AYRE`.
- `BPNL` = Legal entity
- `BPNS` = Site (physical location)

### DID (Decentralized Identifier)
A self-sovereign identity string that maps to a participant's BPN. The DID format depends on the **wallet implementation**:

| Wallet | DID Format | Resolution |
|--------|-----------|------------|
| SSI DIM Wallet Stub (current) | `did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003AYRE` | All DIDs resolve to the single stub host |
| Identity Hub (production) | `did:web:identity-hub-provider.tx.test:BPNL00000003AYRE` | Each DID resolves to the participant's own Identity Hub |

> **In-cluster vs ingress DID form**: The umbrella uses two forms of wallet-stub DID depending on the profile:
> - **Default** (`charts/umbrella/values.yaml`): `did:web:ssi-dim-wallet-stub.tx.test:<BPN>` (ingress hostname, used when consumers/providers resolve DIDs through the cluster ingress).
> - **`values-test-data-exchange.yaml`**: `did:web:ssi-dim-wallet-service:<BPN>` (in-cluster Kubernetes Service DNS, used so EDCs resolve DIDs without going through ingress).
>
> Both are valid — `did:web` simply specifies a host from which `/.well-known/did.json` is fetched. Which form to use depends on whether the client is inside or outside the cluster.

> **Key insight**: With the stub, every participant's DID resolves through one centralized service. With Identity Hub, each participant's DID resolves through their own wallet — which is the whole point of **decentralized** identity.

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
| `tractusx-connector` (0.13.0-rc2, DCP-native) | The EDC itself (control + data plane). The full DCP data exchange has been validated on the EDC-0.17.0-aligned stack (connector `0.13.0-SNAPSHOT`); see `docs/user/common/guides/data-exchange-identity-hub.md`. |
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
| `ssi-dim-wallet-stub` | Simulates a real SSI wallet — issues DIDs, VCs, handles DCP (formerly IATP) |
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
- **Token expiry is very short**: `tokenExpiryTime: "5"` (seconds) by default — see `charts/identity-and-trust-bundle/values.yaml`. Relevant when debugging DCP timeouts; real wallets have much longer TTLs.

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
| BPN Discovery | `semantics.tx.test/bpndiscovery` | Generic `keyType + keyValue → BPN` lookup. Supported key types include `oen`, `wmi`, `manufacturerPartId`, etc. (i.e., OEN/WMI are key **types**, not "part numbers"). |
| Discovery Finder | `semantics.tx.test/discoveryfinder` | Given a discovery type, find the discovery endpoint URL |

Discovery Finder registers BPN Discovery as an endpoint. Applications query Discovery Finder first to learn where to resolve BPNs.

### 6.7 BDRS Server (BPN→DID Resolution)
- In-memory server mapping BPNs to DIDs
- Seeded via post-install hook with **17 BPN↔DID pairs** (15 `BPNL…` legal entities + 2 `BPNS…` sites) — see `bdrs-server-memory.seeding.bpnList` in `charts/umbrella/values.yaml`
- The Portal database is seeded with **16 companies** (legal entities only). The delta vs BDRS is the 2 extra site entries (`BPNS…`) plus the operator BPN `BPNL00000003CRHK`, minus consumers that appear in the company list but not in the data-plane BDRS seed on every profile — always cross-check against the active values file
- EDC connectors query BDRS to resolve a partner's DID from their BPN

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

### Context B: EDC Connector → EDC Connector (DCP via SSI Wallet)
Decentralized authentication for data exchange:
```
Step 1: Consumer EDC asks its Wallet for a Verifiable Presentation
Step 2: Consumer EDC sends VP to Provider EDC
Step 3: Provider EDC verifies VP against trusted issuers
Step 4: Provider EDC checks BDRS for BPN↔DID mapping
Step 5: Contract negotiation proceeds
```

### Detailed DCP Flow (with SSI DIM Wallet Stub)

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

Each EDC connector is configured as below. The connector pinned in this umbrella
is now `0.13.0-rc2` (DCP-native). The example shows the **stub** profile, which
still carries the legacy `iatp:` / `sts.dim` schema; the **identityHub** profiles
use the first-class `dcp:` / `sts.div` keys (see section 7.y):

```yaml
participant:
  id: BPNL00000003AZQP            # Their BPN
iatp:                             # legacy key; the stub profile still uses `iatp` (identityHub profiles use `dcp`)
  id: did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003AZQP
  trustedIssuers:
    - did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003CRHK      # Operator DID
  sts:
    dim:                          # legacy key; identityHub profiles use `div`
      url: http://ssi-dim-wallet-stub.tx.test/api/sts           # Where to get tokens
    oauth:
      token_url: http://ssi-dim-wallet-stub.tx.test/oauth/token
      client:
        id: BPNL00000003AZQP
        secret_alias: edc-wallet-secret                         # Stored in Vault
controlplane:
  env:
    TX_IAM_IATP_CREDENTIALSERVICE_URL: http://ssi-dim-wallet-stub.tx.test/api
  bdrs:
    server:
      url: http://bdrs-server:8081
      # Upstream default cache.validity is 600 seconds (10 min) for BDRS entries.
```

> **Naming note**: Upstream EDC renamed the **concept** `IATP` → `DCP` (adopted in the Eclipse DCP proposal, 2024) and the tractusx-edc `tx-dcp-sts-dim` module was renamed to `tx-dcp-sts-div`. The connector pinned here (`0.13.0-rc2`) is **DCP-native** and exposes first-class `dcp` / `sts.div` keys — the `identityHub` profiles use them (with `participant.id` carrying the DID, `participant.bpnl` the BPN, and `participant.contextId` the plain IdentityHub ParticipantContext id). The **stub** profile above still carries the legacy `iatp` / `sts.dim` keys. Always cross-check `iatp` vs `dcp` and `dim` vs `div` against the profile and the specific tractusx-edc version before editing values files.

---

### How DCP Changes When Identity Hub Replaces the Wallet Stub

The SSI DIM Wallet Stub is a **centralized mock** — one service fakes wallet behaviour for all participants. Identity Hub is the **real DCP-compliant wallet** from the upstream Eclipse EDC project (`eclipse-edc/IdentityHub`), consumed by Tractus-X. Switching to it fundamentally changes the trust architecture.

#### What is Identity Hub?

Identity Hub is a **real DCP-compliant wallet** from the upstream Eclipse EDC project (`eclipse-edc/IdentityHub`, not eclipse-tractusx). It is a per-participant (or multi-tenant) service that implements the full Decentralized Claims Protocol. Tractus-X uses it but it's maintained in the upstream EDC repository.

##### Three Internal Services

Identity Hub is composed of **three distinct services** that can be co-located in one process or distributed across clusters:

| Service | Full Name | Responsibility |
|---------|-----------|---------------|
| **STS** | Secure Token Service | Creates self-issued tokens with VP Access Tokens using the scope scheme from the Base Identity Protocol. Access tokens are always scoped to a participant context. |
| **CS** | Credential Service | Manages Verifiable Credentials — stores, retrieves, and serves VPs. Runs the `VerifiableCredentialManager` state machine for credential lifecycle. |
| **DIDS** | DID Service | Creates, manages, and publishes participant DIDs and DID documents via `DidDocumentPublisher` to a Verifiable Data Registry (VDR). |

##### Two External APIs

| API | Module | Purpose |
|-----|--------|---------|
| **Hub API** | `:core:presentation-api` | External-facing. Implements the DCP **Verifiable Presentation Protocol** (VPP) and **Credential Issuance Protocol** (CIP). Contains: **Presentation API** (external parties request VPs), **Storage API** (issuers write VCs), **Credential Offer API** (receive credential offers). |
| **Identity API** | `:extensions:api:identity-api` | Internal management. CRUD operations on key pairs (rotate, revoke), DID documents (publish, unpublish), credentials (create, renew, delete), and participant contexts. Requires authentication. |

##### Participant Context — The Unit of Management

All identity resources in the Identity Hub are scoped to a **Participant Context** (PC). Each PC is tied to a participant identity (BPN) and contains:
- VerifiableCredentialResources (the stored VCs)
- KeyPairResources (the cryptographic keys)
- DIDResources (the DID and DID document)

Access control is scoped per PC — a token issued for one context cannot access resources in another.

##### Comparison: Stub vs Identity Hub

| Capability | SSI DIM Wallet Stub | Identity Hub |
|-----------|---------------------|-------------|
| DID document hosting | One host serves all DID docs | Each participant hosts their own `/.well-known/did.json` via `DidDocumentPublisher` |
| Verifiable Credential storage | Auto-generated on the fly | Persisted in a credential store (PostgreSQL) with full state machine |
| STS (Secure Token Service) | Shared endpoint for all | Per-participant STS issues Self-Issued (SI) tokens with VP Access Tokens |
| VP (Verifiable Presentation) | Stub fabricates VPs instantly | Real VPs assembled from stored VCs by `VerifiablePresentationService` and signed with participant's private key (from Vault) |
| Credential issuance | Implicit — stub pretends VCs exist | Explicit — Credential Issuer pushes VCs into Identity Hub via Storage API / CIP |
| Key management | No real key management | `KeyPairResource` with rotation/revocation state machine; private keys stored in Vault |
| Trust anchoring | Single trusted issuer DID on stub | Trust chain verified through DID resolution of each issuer's Identity Hub |

#### DCP Flow Today (with SSI DIM Wallet Stub)

```
Consumer EDC ──► Stub /api/sts ──► Stub fabricates SI token + VP
                                    (all in one call, no real crypto)
Consumer EDC ──► Provider EDC   ──► Provider asks Stub to verify
                                    (Stub says "yes" for everything)
```

**Problem**: This is not decentralized at all. The stub is a single point of trust. It doesn't prove the consumer actually holds any credential — it just generates tokens for any BPN that asks.

#### DCP Flow with Identity Hub (Production)

```
┌───────────────────────────────────────────────────────────────────────────┐
│                    FULL DCP CREDENTIAL PRESENTATION FLOW                  │
├───────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  ┌─────────────┐         ┌──────────────────────┐                        │
│  │ Consumer EDC │         │ Consumer Identity Hub │                        │
│  └──────┬──────┘         └──────────┬───────────┘                        │
│         │                           │                                     │
│   1. Consumer EDC needs to call     │                                     │
│      Provider EDC's catalog API     │                                     │
│         │                           │                                     │
│   2. POST /api/sts                  │                                     │
│      {                              │                                     │
│        audience: "did:web:identity-hub-provider.tx.test:BPNL...AYRE",    │
│        scope: "org.eclipse.tractusx.vc.type:MembershipCredential:read"   │
│      }                              │                                     │
│         ├──────────────────────────►│                                     │
│         │                           │                                     │
│         │   3. Identity Hub:        │                                     │
│         │      a. Finds the MembershipCredential VC in its store         │
│         │      b. Verifies the VC is not expired/revoked                  │
│         │      c. Creates a VP wrapping the VC                            │
│         │      d. Signs the VP with consumer's private key (from Vault)  │
│         │      e. Creates a Self-Issued (SI) token containing:           │
│         │         - iss: consumer's DID                                    │
│         │         - sub: consumer's DID                                    │
│         │         - aud: provider's DID (the audience)                    │
│         │         - token: the signed VP                                   │
│         │                           │                                     │
│         │◄──────────────────────────┤  SI Token (JWT)                     │
│         │                           │                                     │
│  ┌──────▼──────┐                    │    ┌──────────────────────┐         │
│  │ Consumer EDC │                    │    │  Provider EDC         │         │
│  └──────┬──────┘                    │    └──────────┬───────────┘         │
│         │                           │               │                     │
│   4. Consumer EDC sends catalog     │               │                     │
│      request with SI token in       │               │                     │
│      Authorization header           │               │                     │
│         ├───────────────────────────┼──────────────►│                     │
│         │                           │               │                     │
│         │                           │    5. Provider EDC receives request  │
│         │                           │       and validates the SI token:    │
│         │                           │               │                     │
│         │                           │       a. Extract issuer DID from JWT │
│         │                           │       b. Resolve DID document:       │
│         │                           │          GET did:web:identity-hub-   │
│         │                           │          consumer1.tx.test:BPNL...  │
│         │                           │          → fetches /.well-known/     │
│         │                           │            did.json from consumer's  │
│         │                           │            Identity Hub              │
│         │                           │       c. Extract public key from     │
│         │                           │          DID document                │
│         │                           │       d. Verify JWT signature with   │
│         │                           │          that public key             │
│         │                           │       e. Extract VP from token       │
│         │                           │       f. Verify VP signature         │
│         │                           │       g. Extract VC from VP          │
│         │                           │       h. Check VC issuer is in       │
│         │                           │          trustedIssuers list         │
│         │                           │       i. Resolve issuer's DID doc   │
│         │                           │          to verify VC signature      │
│         │                           │       j. Check VC not revoked        │
│         │                           │          (status list check)         │
│         │                           │       k. Extract BPN from VC claims  │
│         │                           │       l. Resolve BPN via BDRS to     │
│         │                           │          confirm DID↔BPN binding     │
│         │                           │               │                     │
│         │                           │    6. If all checks pass → evaluate  │
│         │                           │       access policies against the    │
│         │                           │       presented credentials          │
│         │                           │               │                     │
│         │◄──────────────────────────┼───────────────┤  Catalog Response   │
│         │                           │               │                     │
└───────────────────────────────────────────────────────────────────────────┘
```

#### What Changes in Configuration

When Identity Hub replaces the stub, **every EDC connector's DCP config must change**:

```yaml
# BEFORE (Stub) — legacy iatp/sts.dim schema; all connectors share one stub
# (charts/values-test-data-exchange.yaml)
iatp:
  trustedIssuers:
    - did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003CRHK
  sts:
    dim:
      url: http://ssi-dim-wallet-stub.tx.test/api/sts

# AFTER (Identity Hub) — DCP-native dcp/sts schema; the trusted issuer is the
# IssuerService DID, and sts.div.url is left EMPTY so the OAuth2 STS client loads.
# Shared topology shown (charts/values-test-data-exchange-identity-hub.yaml);
# per-participant uses did:web:ih-<role>.tx.test:<BPN> hosts instead.
dcp:
  trustedIssuers:
    - did:web:issuer-service.tx.test:BPNL00000003CRHK
  sts:
    div:
      url: ""
    oauth:
      token_url: http://identity-hub.tx.test/api/sts/token
      client:
        id: did:web:identity-hub.tx.test:BPNL00000003AZQP
        secret_alias: edc-wallet-secret
```

**All touchpoints that change**:

| Component | Config Key | Current (Stub) | With Identity Hub |
|-----------|-----------|----------------|-------------------|
| **EDC participant.id** | `participant.id` | `did:web:ssi-dim-wallet-stub.tx.test:<BPN>` | `did:web:<participant-ih-host>:<BPN>` |
| **EDC dcp.sts** | `dcp.sts.div.url` | `http://ssi-dim-wallet-stub.tx.test/api/sts` | `http://<participant-ih-host>/api/sts` |
| **EDC dcp.oauth** | `dcp.sts.oauth.token_url` | `http://ssi-dim-wallet-stub.tx.test/oauth/token` | `http://<participant-ih-host>/oauth/token` |
| **Portal custodian** | `portal.custodianAddress` | `http://ssi-dim-wallet-stub.tx.test` | `http://identity-hub.tx.test` (operator IH) |
| **Portal DIM wrapper** | `portal.dimWrapper.baseAddress` | `http://ssi-dim-wallet-stub.tx.test` | `http://identity-hub.tx.test` |
| **Portal DIM auth** | `portal.decentralIdentityManagementAuthAddress` | `http://ssi-dim-wallet-stub.tx.test/api/sts` | `http://identity-hub.tx.test/api/sts` |
| **Portal issuerdid** | `portal.backend.administration.issuerdid` | `did:web:ssi-dim-wallet-stub.tx.test:BPNL...CRHK` | `did:web:identity-hub.tx.test:BPNL...CRHK` |
| **Credential Issuer** | `ssi-credential-issuer.walletAddress` | `http://ssi-dim-wallet-stub.tx.test` | `http://identity-hub.tx.test` |
| **BDRS seeding** | `bdrs-server-memory.seeding.bpnList[].did` | `did:web:ssi-dim-wallet-stub.tx.test:<BPN>` | `did:web:<participant-ih-host>:<BPN>` |

#### Credential Lifecycle — The Biggest New Requirement

With the stub, credentials don't really exist — the stub pretends they do. With Identity Hub, there's a real **credential lifecycle** managed by the `VerifiableCredentialManager` with a full state machine:

> **Caveat**: The state names and transitions below reflect the `VerifiableCredentialResource.State` enum in `eclipse-edc/IdentityHub` at the time of writing. The EDC team refactors this area periodically — verify against the current enum in the upstream repo before quoting this in production docs.

```
VerifiableCredentialResource State Machine:
┌─────────┐   request   ┌────────────┐  response   ┌───────────┐  issue   ┌────────┐
│ INITIAL ├────────────►│ REQUESTING ├────────────►│ REQUESTED ├────────►│ISSUING │
└─────────┘             └────────────┘             └───────────┘         └───┬────┘
                                                                             │
                                                                          issued
                                                                             │
┌───────────┐  re-request ┌───────────────────┐  re-respond ┌──────────────────┐  │
│TERMINATED │◄────────────│REISSUE_REQUESTING │◄────────────│REISSUE_REQUESTED │  │
└───────────┘             └───────────────────┘             └──────────────────┘  │
      ▲                                                            ▲              │
      │ revoke/expire                                   auto-renew │              │
      │                                                (near expiry)│              │
      │                   ┌────────┐                               │              │
      └───────────────────┤ ISSUED │◄──────────────────────────────┼──────────────┘
                          └───┬────┘                               │
                              └────────────────────────────────────┘
                              (any state can also → ERROR)
```

The `VerifiableCredentialManager` (VCM):
- Is **cluster-aware** — guarantees only one flow per credential across all runtime instances
- Supports **auto-renewal** when it detects a credential is nearing expiry (configurable, default `true`)
- Dispatches credential requests via the EDC `RemoteMessageDispatcher` using the Credential Issuance Protocol (CIP)
- Delegates to the EDC `PolicyEngine` to evaluate `issuancePolicy` and `reissuancePolicy` (ODRL) before generating tokens for issuer requests

Three things can trigger a credential renewal:
1. An incoming **credential offer** from an issuer (handled by the `OfferProcessor`)
2. The VCM state machine detects **nearing expiry** (if auto-renewal is active)
3. A **manual action** via the Identity API

The complete flow before data exchange can work:

```
1. Company onboards via Portal
        │
2. Portal triggers Credential Issuer to issue MembershipCredential
        │
3. Credential Issuer creates a VC and pushes it to the company's Identity Hub
   (via Hub API → Storage API, or via DCP Credential Issuance Protocol)
        │
4. Identity Hub stores the VC as a VerifiableCredentialResource (state → ISSUED)
   in its credential store (PostgreSQL), scoped to the company's ParticipantContext
        │
5. NOW the company's EDC can request VPs from its Identity Hub
   (the STS creates VP Access Tokens, the CS assembles VPs from stored VCs)
        │
6. Data exchange proceeds via DCP as shown above
```

**If step 3–4 fails or hasn't happened yet**, the EDC connector will get an error from Identity Hub when requesting a VP — the credential simply isn't there. With the stub, this never happens because it fabricates everything.

#### Deployment Architecture Impact

The upstream `eclipse-edc/IdentityHub` architecture document defines **two official deployment topologies**:

1. **Embedded**: Identity Hub runs inside the EDC control-plane runtime (same JVM process)
2. **Standalone**: Identity Hub runs as a separate single or clustered runtime

> **Status (2026-06):** The SSI DIM Wallet Stub remains the **default**, but the dual-wallet IdentityHub option below is now **shipped and validated end-to-end** (full DCP catalog → negotiation → transfer → fetch). Three profiles exist: `values-test-data-exchange-identity-hub.yaml` (shared, multi-tenant IH — sub-option A below), `…-per-participant.yaml` (one IH per participant — shipped as provider + consumer1; sub-option B/C below), and `…-postgres.yaml` (persistent, postgres-backed IH). The A / B / C diagrams below illustrate these topologies. See `docs/user/common/guides/data-exchange-identity-hub.md` and the #1609 plan for the validated stack + caveats.

```
CURRENT (1 stub serves all):
┌──────────────────────────────────────┐
│  SSI DIM Wallet Stub                 │
│  ┌────┐ ┌────┐ ┌────┐               │
│  │BPN1│ │BPN2│ │BPN3│  ...           │ ← All identities in one service
│  └────┘ └────┘ └────┘               │
└──────────────────────────────────────┘

WITH IDENTITY HUB:

Option A — Embedded in EDC (simplest for testing):
┌──────────────────────────────────────────────┐
│ EDC Control Plane + Embedded Identity Hub     │
│  ┌─────────────────┐ ┌───────────────────┐   │
│  │ EDC Control Plane│ │ Identity Hub       │   │
│  │ (catalog, policy,│ │ (STS + CS + DIDS)  │   │
│  │  negotiation)    │ │                    │   │
│  └─────────────────┘ └───────────────────┘   │
│  Same process — no network calls for STS      │
└──────────────────────────────────────────────┘
↑ Lightest — STS calls are in-process. Can even short-circuit
  key resolution by loading KeyPairResource directly from storage.

Option B — Standalone per-participant (most realistic for production):
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│ IH: Provider     │  │ IH: Consumer 1   │  │ IH: Consumer 2   │
│ BPNL...AYRE      │  │ BPNL...AZQP      │  │ BPNL...AVTH      │
│ + PostgreSQL     │  │ + PostgreSQL     │  │ + PostgreSQL     │
│ + Vault keys     │  │ + Vault keys     │  │ + Vault keys     │
└──────────────────┘  └──────────────────┘  └──────────────────┘
↑ Heavy — each participant needs its own IH + DB

Option C — Standalone shared/multi-tenant (practical for umbrella testing):
┌──────────────────────────────────────┐
│  Identity Hub (multi-tenant)         │
│  ┌────┐ ┌────┐ ┌────┐               │
│  │PC:1│ │PC:2│ │PC:3│  ...           │ ← Isolated ParticipantContexts
│  └────┘ └────┘ └────┘               │
│  + PostgreSQL                        │
│  + Vault integration                 │
└──────────────────────────────────────┘
↑ Lighter — shared infrastructure, isolated by ParticipantContext
```

For the **umbrella chart** (testing/dev), Option A or C are most practical. For **production**, Option B (per-participant standalone) is the target architecture.

#### Summary: Stub vs Identity Hub

| Aspect | SSI DIM Wallet Stub | Identity Hub |
|--------|---------------------|-------------|
| **Architecture** | Centralized mock | Decentralized (per-participant or multi-tenant) |
| **Credentials** | Fabricated on demand | Real VCs issued, stored, and presented |
| **Cryptography** | No real signing | Real key pairs; JWTs and VPs are cryptographically signed |
| **DID resolution** | All DIDs resolve to one host | Each DID resolves to the participant's own wallet |
| **Credential issuance** | Not needed | Required before data exchange can work |
| **Revocation** | Not real | Status list credential checks |
| **Trust verification** | Stub always says "yes" | Full DID → public key → signature verification chain |
| **Failure modes** | Almost none (it's a mock) | Missing credentials, expired VCs, revoked VCs, key rotation issues |
| **Production-ready** | No | Yes |

#### How tractusx-edc Implements DCP (Extension Structure)

The tractusx-edc repository (`eclipse-tractusx/tractusx-edc`) provides the EDC DCP integration through these extensions in `edc-extensions/dcp/`:

| Extension | Purpose |
|-----------|---------|
| `cx-dcp` | **Catena-X scope extractors** — extracts credential scopes from EDC policies (e.g., maps a `MembershipCredential` policy constraint to a DCP scope string like `org.eclipse.tractusx.vc.type:MembershipCredential:read`) |
| `tx-dcp` | **Tractus-X DCP integration** — Tractus-X-specific DCP wiring (scope mapping, trust configuration, presentation flow). Note: DCP is the identity/claims protocol; **DSP** (Dataspace Protocol) is the separate data-plane protocol handled by the core EDC dsp modules. |
| `tx-dcp-sts-div` | **STS client** for Identity Hub's STS endpoint — requests SI tokens. The module was renamed from `tx-dcp-sts-dim` → `tx-dcp-sts-div` in tractusx-edc; the expansion of "DIV" is **not officially defined in upstream docs** (do not assume "Decentralized Identity Verification"). |
| `verifiable-presentation-cache` | **VP caching** — caches resolved Verifiable Presentations for performance. Cache validity is configurable per key; there is **no single fixed default** — verify against the tractusx-edc version in use. |

Additional DCP-related extensions in tractusx-edc:

| Extension | Purpose |
|-----------|---------|
| `edc-extensions/did-document/` | DID document handling for the connector |
| `edc-extensions/bdrs-client/` | BPN/DID Resolution Service client — resolves partner BPNs to DIDs; has configurable cache validity (default 600s) |
| `edc-extensions/bpn-validation/` | Validates BPN claims in presented credentials |
| `edc-extensions/cx-policy/` | Catena-X policy definitions and evaluators |
| `edc-extensions/token-interceptor/` | Intercepts and enriches tokens in the DCP flow |
| `edc-extensions/tokenrefresh-handler/` | Handles token refresh logic for long-running transfers |

The Identity Hub's DCP protocol implementation (`eclipse-edc/IdentityHub`, `protocols/dcp/`) contains the following modules (names current at time of writing; this area is refactored periodically — verify against the upstream repo before citing):

| Module | Purpose |
|--------|---------|
| `dcp-core` | Core DCP protocol types and logic |
| `dcp-spi` | Service Provider Interfaces for DCP extensions |
| `dcp-identityhub` | Identity Hub-side DCP implementation: `presentation-api`, `storage-api`, `credential-offer-api`, `credentials-api-configuration` |
| `dcp-issuer` | Issuer-side DCP implementation: `dcp-issuer-api`, `dcp-issuer-core`, `dcp-issuer-spi` |
| `dcp-transform-lib` | JSON-LD transformers for DCP protocol messages |
| `dcp-validation-lib` | Validators for DCP protocol messages |

#### Key Pair Management in Identity Hub

Identity Hub manages `KeyPairResources` with a lifecycle state machine:

```
┌─────────┐  activate  ┌───────────┐  rotate  ┌─────────┐  revoke  ┌─────────┐
│ INITIAL ├───────────►│ ACTIVATED ├─────────►│ ROTATED ├────────►│ REVOKED │
└─────────┘            └───────────┘          └─────────┘         └─────────┘
                        (any state can also → ERROR)
```

Key concepts:
- Each `KeyPairResource` has a `groupName` — services are configured with a group to indicate which key pair to use for signing
- Only one `KeyPairResource` should be active per group
- `useDuration`: how long (ms) a key stays ACTIVATED before auto-rotation starts (`-1` = indefinite, manual trigger)
- `rotationDuration`: how long (ms) a key stays ROTATED before auto-revocation (`-1` = indefinite, manual trigger)
- Private keys are stored in Vault; public keys are in the DID document as verification methods

**Key rotation** involves:
1. Creating a new `KeyPairResource` in the same group
2. Destroying the old private key
3. Adding a new verification method to the DID document
4. Publishing the updated DID document

**Key revocation** involves:
1. Transitioning from ROTATED → REVOKED
2. Removing the verification method from the DID document
3. Publishing the updated DID document

---

### 7.x Adjacent Protocols and Concepts (Often Asked About)

These aren't covered in depth above but matter for anyone doing real data-exchange work on Tractus-X:

#### DSP — Dataspace Protocol (distinct from DCP)
- DSP is the **data-plane / contract-negotiation** protocol between EDCs. DCP is the **identity/claims** protocol. They are layered, not the same thing.
- Version matters: this umbrella pins `tractusx-connector` 0.13.0-rc2, whose `tractusx-edc` 0.13 line **dropped DSP 0.8** in favour of newer DSP revisions — the data-exchange profiles negotiate over `dataspace-protocol-http:2025-1`. Cross-check the DSP version when changing the connector chart.

#### EDR — Endpoint Data Reference
- The artifact a **consumer** receives after a successful transfer process initiation. It contains the actual endpoint URL + a short-lived access token the consumer uses to fetch data from the provider's data plane.
- Without an EDR, "contract agreed" means nothing — the EDR is what the consumer application actually consumes.
- Delivered via callback or pulled from the consumer control plane's `/edrs` endpoint.

#### ODRL / Policy Engine
- Policies in Tractus-X are expressed in **ODRL** (Open Digital Rights Language).
- The EDC `PolicyEngine` evaluates policies at three key points: catalog filtering, contract negotiation, and transfer initiation.
- Tractus-X defines specific policy constraints (e.g., `FrameworkAgreement.traceability`, `Membership`) via the `cx-policy` extension.
- For production, policy design is where most real-world governance complexity lives — far more than the transport protocol.

#### Token Refresh (tokenrefresh-handler)
- For long-running transfers (streaming, large datasets), the short-lived EDR access token would expire mid-transfer.
- The `tokenrefresh-handler` extension in tractusx-edc handles refreshing these tokens transparently via a refresh endpoint exposed by the provider's data plane.
- Relevant config: refresh endpoint, refresh token expiry, and the Vault-stored signing keys used to mint new access tokens.

---

### 7.y Choosing a Wallet Implementation (Stub vs Identity Hub)

The umbrella supports **two wallet implementations as peers**. Which one is active is controlled by a single top-level `wallet.mode` in `charts/umbrella/values.yaml` plus a corresponding Helm chart toggle in `charts/identity-and-trust-bundle`.

| Mode | Wallet chart(s) under `identity-and-trust-bundle` | Profile file |
|---|---|---|
| `stub` (default) | `ssi-dim-wallet-stub` | `charts/values-test-data-exchange.yaml` |
| `identityHub` — shared | `identity-hub` (in-memory) + `issuer-service` | `charts/values-test-data-exchange-identity-hub.yaml` |
| `identityHub` — per-participant | two in-memory IdentityHubs (provider + consumer1, one per participant) + `issuer-service` | `charts/values-test-data-exchange-identity-hub-per-participant.yaml` |
| `identityHub` — persistent | `identity-hub-postgres` + `issuer-service` | `charts/values-test-data-exchange-identity-hub-postgres.yaml` |

`_wallet-validate.tpl` enforces a **3-way** mutual exclusion — exactly one of `stub` \| `identity-hub` (in-memory) \| `identity-hub-postgres` may be enabled. Running the validated DCP flow today also needs the `charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml` image overlay (the EDC-0.17.0 connector + IdentityHub/IssuerService 0.17.0 builds are not yet on a public release channel) — see the deploy guide.

#### How the toggle works

- **Mutual exclusion** is enforced by a Helm template validator at `charts/umbrella/templates/_wallet-validate.tpl`. If both wallets are enabled, or if `wallet.mode` is out of sync with which chart is enabled, `helm install` fails with a clear error.
- The always-rendered `configmap-wallet-mode.yaml` carries the active mode as a label (`tractusx.eclipse.org/wallet-mode`) so operators can see which wallet any deployed release is using.
- Each aliased `tx-data-provider` instance (`dataconsumerOne`, `dataconsumerTwo`, provider) also reads `wallet.mode` so it can conditionally render Identity-Hub-specific post-install hooks.

#### What changes between the two profiles

| Config area | `stub` profile (legacy `iatp` schema) | `identityHub` profiles (DCP-native `dcp` schema) |
|---|---|---|
| participant DID | `iatp.id: did:web:ssi-dim-wallet-stub.tx.test:<BPN>` | `participant.id: did:web:identity-hub.tx.test:<BPN>` (or the per-host `ih-<role>.tx.test` DID in per-participant) |
| trusted issuer | `iatp.trustedIssuers:` operator DID on the stub | `dcp.trustedIssuers: [did:web:issuer-service.tx.test:<issuer BPN>]` — the IssuerService signs the VCs |
| STS token endpoint | `iatp.sts.dim.url: http://ssi-dim-wallet-stub.tx.test/api/sts` | `dcp.sts.oauth.token_url: http://identity-hub.tx.test/api/sts/token` (`dcp.sts.div.url` left empty ⇒ OAuth2 STS client) |
| credential-service URL | `TX_IAM_IATP_CREDENTIALSERVICE_URL: http://ssi-dim-wallet-stub.tx.test/api` | `TX_EDC_IAM_DCP_CREDENTIALSERVICE_URL: http://identity-hub.tx.test/api/credentials/v1/participants/<plain ctxId>` |
| participant context id | _(n/a)_ | `participant.contextId: <role>-<bpn-lowercased>` — **plain** (EDC 0.17.0 / IH #937), not base64 |
| BDRS seeding DIDs | `did:web:ssi-dim-wallet-stub.tx.test:<BPN>` | `did:web:identity-hub.tx.test:<BPN>`, seeded by `post-install-bdrs-setup.yaml` |
| Portal / `ssi-credential-issuer` addresses | Stub URLs | Identity Hub / Issuer Service URLs |
| Credential seeding | Not needed (stub fabricates VCs) | `post-install-identityhub-seed.yaml` creates ParticipantContexts and issues per-type claims (`BpnCredential.bpn`, `DataExchangeGovernanceCredential.contractVersion`, `MembershipCredential`, …) |

#### Naming note (important)

The connector pinned here (`0.13.0-rc2`) is **DCP-native**: the `identityHub` profiles use the `dcp` / `sts.div` / `participant.*` keys above, while the `stub` profile still carries the legacy `iatp` / `sts.dim` keys. So the schema you edit depends on the profile — cross-check before changing values.

#### Files you will touch to keep both wallets supported

```
charts/umbrella/values.yaml                                   # wallet.* block, single source of truth
charts/umbrella/templates/_wallet-validate.tpl                # mutual-exclusion validator
charts/umbrella/templates/configmap-wallet-mode.yaml          # always-rendered; triggers validator
charts/identity-and-trust-bundle/Chart.yaml                   # optional identity-hub + issuer-service deps
charts/identity-and-trust-bundle/values.yaml                  # default values for both wallet options
charts/values-test-data-exchange.yaml                         # stub profile (unchanged)
charts/values-test-data-exchange-identity-hub.yaml            # NEW — Identity Hub profile
charts/tx-data-provider/values.yaml                           # wallet.mode propagation key
charts/tx-data-provider/templates/post-install-identityhub-seed.yaml  # NEW — guarded seeding hook
```

#### Current status and known limitations

This wallet path is **implemented and validated end-to-end** (catalog → contract
negotiation → transfer → fetch) on all three IdentityHub topologies — see the
[Data Exchange with Real IdentityHub](docs/user/common/guides/data-exchange-identity-hub.md)
guide. The IdentityHub / IssuerService charts are pinned at `v0.3.2`, and the
seeding hook `post-install-identityhub-seed.yaml` is a full implementation of the
DCP provisioning walkthrough: it creates each ParticipantContext, activates the
`did:web`, registers holders + credential definitions on the IssuerService, issues
the per-type credentials, and a BDRS hook seeds the BPN→DID directory.

Known limitations (all covered in the deploy guide):

- **The released pins cannot complete the transfer yet.** The bundle `Chart.yaml`s
  pin the released 0.16.0 line (connector `0.13.0-rc2`, IH/IS `v0.3.2`), which
  predates the plain-`participantContextId` change (EDC 0.17.0 / IH #937). The
  validated flow needs the EDC-0.17.0-aligned builds — connector from `tractusx-edc`
  `main` and IdentityHub/IssuerService from
  [PR #309](https://github.com/eclipse-tractusx/tractusx-identityhub/pull/309) —
  pinned by `values-test-data-exchange-identity-hub-local-0.17.0.yaml`. A render
  guard (`_wallet-validate.tpl`) fails any `wallet.mode=identityHub` install that
  omits this overlay, so the non-working stack is never run silently. The guard and
  overlay are removed once the upstream releases land and the pins are bumped.
- **In-memory IdentityHub/BDRS lose state on pod restart** (shared / per-participant
  topologies); the persistent (postgres) profile keeps ParticipantContexts +
  credentials across restarts. Re-seed after a restart, or use the postgres profile —
  see the deploy guide's re-seeding runbook.

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
     (authenticated via DCP/VP)
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
1. Writes `edc-wallet-secret` to Vault (used for DCP authentication)
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
secret/data/edc-wallet-secret       → The DCP client secret (for STS DIV OAuth)
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
# In Chart.yaml (version must match charts/tx-data-provider/Chart.yaml — currently 0.5.0)
- name: tx-data-provider
  alias: myNewParticipant
  version: 0.5.0
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
| **DCP** | Decentralized Claims Protocol — the protocol for credential presentation between connectors. The concept was renamed from **IATP** upstream (Eclipse DCP proposal, 2024). The connector pinned here (`0.13.0-rc2`) is DCP-native: the `identityHub` profiles use the `dcp` Helm values key; the `stub` profile still uses the legacy `iatp` key. |
| **DID** | Decentralized Identifier — self-sovereign identity identifier |
| **DIV** | Name of the renamed STS client module in tractusx-edc (previously `tx-dcp-sts-dim`). The expansion of "DIV" is **not officially defined** in upstream docs — do not assume "Decentralized Identity Verification". The module talks to Identity Hub's STS. The `identityHub` profiles use the `sts.div` key; the legacy `stub` profile still uses `sts.dim`. |
| **DTR** | Digital Twin Registry |
| **EDC** | Eclipse Dataspace Connector |
| **Hub API** | Identity Hub's external API — implements the DCP Verifiable Presentation Protocol (Presentation API + Storage API) and Credential Issuance Protocol (Credential Offer API) |
| **IATP** | Identity and Trust Protocol (now DCP) |
| **Identity API** | Identity Hub's internal management API — CRUD on DIDs, keys, credentials, and ParticipantContexts |
| **Identity Hub** | Eclipse EDC upstream wallet (`eclipse-edc/IdentityHub`) — manages DIDs, stores VCs, provides STS/CS/DIDS services; replaces the SSI DIM Wallet Stub. Used by Tractus-X but maintained in the upstream EDC project |
| **IDP** | Identity Provider (Keycloak) |
| **SAMM** | Semantic Aspect Meta Model |
| **SI Token** | Self-Issued Token — a JWT issued by Identity Hub's STS, containing a VP Access Token as proof of identity |
| **SSI** | Self-Sovereign Identity |
| **STS** | Secure Token Service — Identity Hub service that issues SI tokens; creates VP Access Tokens using the scope scheme from the Base Identity Protocol |
| **VC** | Verifiable Credential — a signed attestation (e.g., MembershipCredential proving dataspace membership); managed through a state machine (INITIAL → REQUESTING → REQUESTED → ISSUING → ISSUED → TERMINATED) |
| **VP** | Verifiable Presentation — a signed wrapper around one or more VCs, created for a specific audience by the VerifiablePresentationService |
| **VDR** | Verifiable Data Registry — where DID documents are published (e.g., a CDN or web server serving `/.well-known/did.json`) |
| **ParticipantContext** | The unit of management in Identity Hub — scopes all identity resources (VCs, keys, DIDs) to a specific participant identity (BPN) |
| **CIP** | Credential Issuance Protocol — the DCP sub-protocol for requesting and issuing Verifiable Credentials |
| **VPP** | Verifiable Presentation Protocol — the DCP sub-protocol for requesting and serving Verifiable Presentations |

---

*Generated from codebase analysis of Eclipse Tractus-X Umbrella v3.17.0 (`charts/umbrella/Chart.yaml`).*
