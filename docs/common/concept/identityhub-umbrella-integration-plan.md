<!--
#############################################################################
Copyright (c) 2026 Contributors to the Eclipse Foundation

See the NOTICE file(s) distributed with this work for additional
information regarding copyright ownership.

This program and the accompanying materials are made available under the
terms of the Apache License, Version 2.0 which is available at
https://www.apache.org/licenses/LICENSE-2.0.

SPDX-License-Identifier: Apache-2.0
#############################################################################
-->

# IdentityHub Data Exchange — Umbrella Integration Plan

> Per-repository action plan for replacing the SSI DIM wallet stub with a
> real, decentralized IdentityHub-based wallet in the Tractus-X Umbrella
> deployment.

---

## 1. Executive summary

The Tractus-X Umbrella chart today ships `ssi-dim-wallet-stub` — an
in-memory fake of SAP's DIM wallet — as the credential service for every
participant in the data-exchange profile. This document describes the
work required to replace that stub with a production-shaped wallet
based on `tractusx-identityhub` (the Tractus-X distribution of the
Eclipse EDC `IdentityHub` reference runtime).

**Five repositories are involved.** None of the gating work lives in
`eclipse-edc/Connector` or `eclipse-edc/IdentityHub`; both upstream
projects already provide the SPIs and runtime modules required by DCP.
The work is concentrated in the Tractus-X distribution layer
(`tractusx-identityhub`) and in the umbrella chart itself.

**Scope decision for v1: data-exchange profile only.** The Portal /
onboarding stack (Portal-backend, BPDM, central-IdP, shared-IdP,
SSI-Credential-Issuer) keeps using the wallet stub in v1. The
Portal-backend "Bring Your Own Wallet" (BYOW) feature is merged
upstream and unblocks Portal+IH in a later iteration; we treat that
as a v2 follow-up rather than the v1 deliverable.

**Reference implementations (informational, not adopted as-is).**

- [`Federity-X/public-tractusx-edc#dcp-v2`](https://github.com/Federity-X/public-tractusx-edc/tree/dcp-v2/deployment/local) — end-to-end Docker Compose flow with IH 0.15.1.
- [`Federity-X/public-tractusx-identityhub#dcp-flow-local-deployment-with-upstream-0.15.1`](https://github.com/Federity-X/public-tractusx-identityhub/tree/dcp-flow-local-deployment-with-upstream-0.15.1) — IH chart side of the same flow.
- [`tractus-x-umbrella#396`](https://github.com/eclipse-tractusx/tractus-x-umbrella/pull/396) — first Helm-layer attempt against the umbrella.

These are the empirical anchors for this plan. They are not directly
mergeable: PR #396 disables the stub instead of feature-flagging, uses
`file://` chart paths, depends on a `0.7.0-SNAPSHOT` BDRS, and requires
a 12-step manual Bruno run. The work below extracts the required
deliverables from those references.

---

## 2. Target architecture

| Component | Role | Source |
|---|---|---|
| Per-participant **IdentityHub** + Vault + Postgres | DID + VC wallet, presentation API, STS | `eclipse-tractusx/tractusx-identityhub` |
| Shared **IssuerService** | Issues `MembershipCredential`, `BpnCredential`, `UsagePurposeCredential`, `DataExchangeGovernanceCredential` | `eclipse-tractusx/tractusx-identityhub` |
| Central **BDRS** | BPN ↔ DID directory | `eclipse-tractusx/bpn-did-resolution-service` |
| Tractus-X **EDC connectors** (CP+DP) per participant | DSP, contracts, transfers | `eclipse-tractusx/tractusx-edc` |
| Umbrella chart | Composition + adopter profiles | `eclipse-tractusx/tractus-x-umbrella` |

**Wallet-agnostic protocol layer.** Eclipse EDC's DCP authentication,
presentation verification, and SI-token validation paths are not
wallet-specific. The upstream Eclipse projects are already
DCP-compliant on the 0.16+ line (`Connector` 0.16.0, `IdentityHub`
0.17.0); no upstream change is required there. The work is to
**re-pin the Tractus-X distributions** onto that line (Section 2.5).

**Control over DID Document service entries** (DSP URL, CredentialService
URL) is delegated through the Tractus-X-specific `DidDocumentServiceClient`
SPI in `tractusx-edc`. We discuss two ways to satisfy this requirement
(declarative seeding at install time vs. runtime mutation through the
SPI) in Section 6.

### 2.1 Identity data model

Each participant carries a triple of identifiers. The schema split in
[`tractusx-edc PR #2742`](https://github.com/eclipse-tractusx/tractusx-edc/pull/2742)
exposes all three on the connector chart's `participant.*` block:

| Field | Type | Source of truth | Used for |
|---|---|---|---|
| `participant.id` | `did:web:<host>:<bpnl>` | minted by the operator at onboarding | DSP `dspace:participantId`, DCP token `iss/sub`, DID-document URL |
| `participant.bpnl` | `BPNL[0-9A-Z]{12}` | Catena-X BPDM | BDRS lookup key, business-level identifier in VCs |
| `participant.contextId` | UUID | minted by IH at participant creation | IH-internal participant context (path segment in `/v1/unstable/participants/{contextId}/...`); decouples the DID from IH's storage primary key so a DID can be rotated without rebuilding IH state |

Worked example (umbrella default `dataconsumerOne`):

```text
bpnl       = BPNL00000003AZQP
host       = dataconsumer-1-identityhub.tx.test
participant.id  = did:web:dataconsumer-1-identityhub.tx.test:BPNL00000003AZQP
contextId  = 11111111-1111-1111-1111-111111111111   # seeded by chart values
```

The corresponding DID Document (served by IH at
`http://dataconsumer-1-identityhub.tx.test/BPNL00000003AZQP/did.json`
when `didweb.https=false`) has the shape:

```json
{
  "@context": ["https://www.w3.org/ns/did/v1", "https://w3id.org/security/suites/jws-2020/v1"],
  "id": "did:web:dataconsumer-1-identityhub.tx.test:BPNL00000003AZQP",
  "verificationMethod": [{
    "id": "did:web:...:BPNL00000003AZQP#key-1",
    "type": "JsonWebKey2020",
    "controller": "did:web:...:BPNL00000003AZQP",
    "publicKeyJwk": { "kty": "EC", "crv": "P-256", "x": "...", "y": "...", "kid": "key-1" }
  }],
  "authentication":      ["did:web:...:BPNL00000003AZQP#key-1"],
  "assertionMethod":     ["did:web:...:BPNL00000003AZQP#key-1"],
  "service": [
    { "id": "#credential-service",
      "type": "CredentialService",
      "serviceEndpoint": "http://dataconsumer-1-identityhub.tx.test/api/credentials/v1/participants/<base64url-did>" },
    { "id": "#data-service",
      "type": "DataService",
      "serviceEndpoint": "http://dataconsumer-1-controlplane.tx.test/api/v1/dsp" }
  ]
}
```

Two invariants hold across the umbrella:

1. The **DID host segment** equals the IH ingress host. If they
   diverge, `did:web` resolution fails (Risk R6).
2. The **JWK `kid`** in `verificationMethod[0].publicKeyJwk` matches the
   `kid` of the private JWK seeded into Vault at alias
   `tokenSignerPrivateKey` (Section 5.5). The connector signs SI-tokens
   with that private key; verifiers fetch the public JWK via DID
   resolution.

### 2.2 Trust model and credential lifecycle

Three actors, three duties:

| Actor | Run by | Duty |
|---|---|---|
| **Issuer** | `tractusx-issuerservice` | Mints VCs (`MembershipCredential`, `BpnCredential`, `UsagePurposeCredential`, `DataExchangeGovernanceCredential`); maintains a status list for revocation. Its DID is the **trust anchor** for every verifier. |
| **Holder** | each participant's `tractusx-identityhub` | Stores received VCs in IH Postgres; on a DCP presentation request, builds a Verifiable Presentation (VP), signs it with the participant's `tokenSignerPrivateKey`, returns it. |
| **Verifier** | each participant's `tractusx-edc` connector | On every DSP step requiring proof, calls the counter-party's CredentialService, verifies VP signature against the counter-party's DID Document, checks each VC's `issuer` against the configured `dcp.trustedIssuers[]`, and checks status-list. |

Lifecycle for one participant:

```
onboarding (manual / Section 5.4 Job)
   │
   ▼
IssuerService participant + attestation + credentialDefinition  (5.4 step 3)
   │
   ▼
Issuance request per VC type            ────►   VC stored in holder's IH    (5.4 step 4)
                                                (Postgres table 'credentials')
   │
   ▼
DSP runtime: catalog / contract / transfer
   │
   ▼
Verifier requests presentation ────►  Holder IH at /api/credentials/v1/...
                                      Holder builds VP, signs with tokenSigner
                                      Verifier checks status-list at IssuerService
```

**Status-list strategy.** IssuerService publishes a
`StatusList2021Credential` at a stable URL; each issued VC carries a
`credentialStatus` pointer with bit position. Verifiers MUST resolve
the status credential at verification time. v1 ships with all
issued VCs marked active (no revocation tooling).

**Trust anchor in v1.** A single IssuerService instance running at
`did:web:tractusx-issuerservice.tx.test:BPNL00000003CRHK` is the
trust anchor for the data-exchange profile. The connector's
`dcp.trustedIssuers[]` lists exactly this DID with the four supported
VC types. Adopters wishing to swap the trust anchor change one umbrella
value (Section 5.8).

### 2.3 Runtime call sequence — DSP exchange in IdentityHub mode

This is the runtime view that complements the build-time critical path
in Section 7. Provider P offers an asset; Consumer C requests it.

```
C-connector ──(1) GET /catalog─────────────────────────► P-connector
                                                          │
                                  (2) BDRS GET /api/directory?bpn=<C.bpnl>
                                                          ▼
                                                       BDRS-server  ── returns C.did
                                                          │
                                  (3) DID resolution     ▼
                                  http://<C.host>/<C.bpnl>/did.json   (C's IH ingress)
                                                          │
                                  (4) DSP CredentialRequest with required scopes
P-connector ──────────────────────────────────────────► C-IH /api/credentials/v1
                                                          │
                                  (5) VP built+signed     ▼
                                       (kid=key-1, alg=ES256)
                                       returns to P-connector
                                                          │
                                  (6) verify VP sig (against C DID Doc)
                                      check trustedIssuers
                                      resolve status-list at IssuerService
                                                          │
                                  (7) issue catalog / contract offer ────────► C
                                                          │
            on contract agreement:  STS round-trip per Section 6.1 option B/A
                                                          │
                                  (8) DataPlane EDR token issued, transfer starts
```

Steps 4–6 repeat for the contract-negotiation and transfer-process
phases (each requires fresh proof). Every IH call uses the holder's
own DID context; no pod talks to another participant's IH directly.

### 2.4 Per-participant deployment topology

Per participant the following pods run in the umbrella namespace
(connector pods unchanged from today):

| Pod | Image | Ports | Ingress hostname | Auth |
|---|---|---|---|---|
| `<p>-identityhub` | `tractusx-identityhub` | 8081 health, 8082 admin, 8083 credentials, 8084 DID, 8085 STS-acct, 8086 well-known, 8087 STS | `<p>-identityhub.tx.test` (must equal DID host segment) | `X-Api-Key` on 8082/8085; DCP token on 8083; per-token on 8087 |
| `<p>-identityhub-postgresql` | `bitnami/postgresql` | 5432 | none | participant-scoped credentials |
| `<p>-vault` | `hashicorp/vault` | 8200 | none | Vault token; seeded by `postStart` (Section 5.5) |
| `<p>-controlplane`, `<p>-dataplane` | `tractusx-connector` | as today | `<p>-controlplane.tx.test`, `<p>-dataplane.tx.test` | as today |

Cluster-shared:

| Pod | Image | Hostname | Purpose |
|---|---|---|---|
| `bdrs-server-memory` | `bdrs-server-memory` | `bdrs-server-memory` (svc) | BPN↔DID directory; **not** ingress-exposed |
| `tractusx-issuerservice` | `tractusx-issuerservice` | `tractusx-issuerservice.tx.test` | issuance, status-list |

The hostname↔DID invariant from Section 2.1 means an adopter renaming the IH
ingress **must** re-issue every participant's DID. There is no
runtime-rename path in v1.

### 2.5 Version compatibility matrix

DCP composability requires every Tractus-X repo in the data-exchange
profile to align on the **same upstream Eclipse-EDC line**. As of the
current `main` of each repo (5 May 2026), the three Tractus-X repos
that compose the data-exchange path are pinned to **three different
upstream EDC versions**, which is the substantive obstacle this plan
must close before v1 can ship.

**Current state — what each Tractus-X repo points to today (`main`):**

| Tractus-X repo | Current TX version (`main`) | Current upstream pin | Where it's pinned |
|---|---|---|---|
| `eclipse-tractusx/tractusx-edc` | `0.13.0-SNAPSHOT` | `edc = "0.15.1"` (and `edc-next = "0.16.0"` for TCK only) | [`gradle/libs.versions.toml`](https://github.com/eclipse-tractusx/tractusx-edc/blob/main/gradle/libs.versions.toml) |
| `eclipse-tractusx/tractusx-identityhub` | chart `v0.2.0`, app `0.2.0` | `edc = "0.14.0"` | [`gradle/libs.versions.toml`](https://github.com/eclipse-tractusx/tractusx-identityhub/blob/main/gradle/libs.versions.toml) |
| `eclipse-tractusx/bpn-did-resolution-service` | `0.7.0-SNAPSHOT` (last release `0.6.0`) | `edc = "0.16.0"` | [`gradle/libs.versions.toml`](https://github.com/eclipse-tractusx/bpn-did-resolution-service/blob/main/gradle/libs.versions.toml) |
| `eclipse-tractusx/ssi-dim-wallet-stub` | chart `0.1.17` | n/a (no Eclipse-EDC link) | — |

The spread (EDC 0.14 ↔ 0.15.1 ↔ 0.16) is *the* problem statement.
A `tractusx-edc` 0.13.0-SNAPSHOT build (EDC 0.15.1) wired against a
`tractusx-identityhub` 0.2.0 build (EDC 0.14.0) will fail at runtime
on:

- DCP presentation-request shape (changed between EDC 0.14 and 0.15),
- `participant.*` schema split — only present from EDC 0.16
  ([PR #2742](https://github.com/eclipse-tractusx/tractusx-edc/pull/2742)),
- IH Identity Admin API path — `/v1/unstable/...` only exists from
  IdentityHub 0.16 onward.

There is **no compatibility shim** between these versions; the EDC
project does not maintain backports.

**Target state — what v1 requires (single coherent line):**

| Tractus-X repo | Required TX version (v1) | Required upstream pin | Status / gate |
|---|---|---|---|
| `eclipse-tractusx/tractusx-edc` | first chart release containing [PR #2742](https://github.com/eclipse-tractusx/tractusx-edc/pull/2742) | `eclipse-edc/Connector` **≥ 0.16.0** | TX-EDC `main` must bump `edc = "0.16.0"` (currently 0.15.1). Tracked under [`sig-release#1609`](https://github.com/eclipse-tractusx/sig-release/issues/1609) (R26.06 bundle). |
| `eclipse-tractusx/tractusx-identityhub` | chart `≥ 0.2.1`, app build re-pinned to IH 0.16+ | `eclipse-edc/IdentityHub` **≥ 0.16.0** (target 0.17.0 to pick up [PR #880](https://github.com/eclipse-edc/IdentityHub/pull/880) OAuth2 on Issuer-Admin API) | TX-IH `main` must bump `edc = "0.16.0"` (currently 0.14.0). Chart `v0.2.1` further requires PR #258 + Section 4.3.2 to land. |
| `eclipse-tractusx/tractusx-identityhub` (IssuerService variant) | chart `≥ 0.2.1` | `eclipse-edc/IdentityHub` **≥ 0.16.0** | same repo, same bump. Gated on Section 4.3.4 publish. |
| `eclipse-tractusx/bpn-did-resolution-service` | chart `0.6.0` (released) or later snapshot | `eclipse-edc/Connector` **0.16.0** | **already aligned** — BDRS is the only Tractus-X repo on the target EDC line today. |
| `eclipse-tractusx/ssi-dim-wallet-stub` | chart `0.1.17` | n/a | retained for legacy `wallet-stub` profile via feature flag (Section 5.1). |

**The two upstream-pin bumps that gate this plan** are therefore:

1. **`tractusx-edc`: bump `edc` from 0.15.1 → 0.16.0** in
   `gradle/libs.versions.toml` and cut a chart release. This is
   precisely what [`sig-release#1609`](https://github.com/eclipse-tractusx/sig-release/issues/1609)
   schedules into R26.06.
2. **`tractusx-identityhub`: bump `edc` from 0.14.0 → 0.16.0 (or 0.17.0)**
   in `gradle/libs.versions.toml` and cut chart `v0.2.1`. PR #258
   (templated ConfigMap names) is the visible chart-side change but
   the silent prerequisite is the upstream EDC bump.

Both bumps are tracked by the EDC Board under R26.06 alongside
[`tractusx-edc#2678`](https://github.com/eclipse-tractusx/tractusx-edc/issues/2678)
(IH client SPI). BDRS is already on 0.16.0 and needs no work here.

**Why this alignment is non-negotiable.** The DCP modules in EDC 0.16
introduced the `participant.contextId` / `participant.bpnl` schema
split (Section 2.1) and the `dcp.*` config namespace
([PR #2742](https://github.com/eclipse-tractusx/tractusx-edc/pull/2742)).
The matching presentation-protocol and Identity-Admin-API changes
landed in IdentityHub 0.16+ (`/v1/unstable/...` surface, Section 4.2).
Connector and IdentityHub running on different EDC lines fail at the
token-shape and API-path level, not at config-key level.

**Other umbrella deps (no upstream Eclipse pin needed):**

| Component | Version | Source |
|---|---|---|
| Postgres (per-IH) | bundled by `tractusx-identityhub` chart (`postgresql 12.12.x`) | upstream default |
| Vault (per participant) | bundled by `dataspace-connector-bundle` (`vault 0.29.1` in IH chart, `0.28.0` in tx-connector chart) | upstream default; minor mismatch acceptable |

**Open external dependency.** Until both upstream bumps above ship,
the umbrella cannot consume the new `dcp.*` schema or the new IH
API surface, and Sections 5.1–5.9 remain blocked. The umbrella's
own deliverables are otherwise ready to land in the order described
in Section 7.

---

## 3. Current-state analysis of the umbrella

A direct read of `charts/umbrella/values.yaml` shows that
`ssi-dim-wallet-stub` is wired into **eight independent code paths**, not
one. Naively swapping the chart will break the seven that have no
IdentityHub equivalent.

| # | Consumer (umbrella values key) | Endpoint shape | IH-replaceable? |
|---|---|---|---|
| 1 | `tractusx-connector.iatp.sts.dim.url` (per participant, lines 1092 / 1183 / 1349) | DIM Secure Token Service `POST /api/sts` | ❌ Different shape — see Section 6.1 |
| 2 | `tractusx-connector.iatp.sts.oauth.token_url` | OAuth2 client_credentials for DIM | ❌ Not used by IH |
| 3 | `tractusx-connector.controlplane.env.TX_IAM_IATP_CREDENTIALSERVICE_URL` (lines 1100 / 1120 / 1191 / 1211 / 1357 / 1377) | DCP CredentialService API | ✅ IH **is** a CredentialService |
| 4 | `tractusx-connector.controlplane.bdrs.server.url` (lines 1104 / 1195 / 1361) | BDRS `/api/v1/directory` | ✅ Repoint to real BDRS |
| 5 | `portal.custodianAddress` (line 54) | MIW REST API | ❌ IH is not MIW |
| 6 | `portal.dimWrapper.{baseAddress,tokenAddress}` (lines 56–58) and `portal.backend.processesworker.dim.baseAddress` (line 183) | SAP-DIM wallet provisioning | ❌ Not in IH |
| 7 | `portal.decentralIdentityManagementAuthAddress` (line 59) | DIM `/api/sts` | ❌ Not in IH |
| 8 | `ssi-credential-issuer.{walletAddress,walletTokenAddress,credential.statusListUrl}` (lines 802–818) | DIM-shape wallet + Status List 2021 | ❌ Replace with `tractusx-issuerservice` (separate workstream) |

Items 5–8 belong to the **Portal / onboarding stack** and have no
IdentityHub equivalent. v1 therefore restricts the IH switch to the
**data-exchange profile** only (i.e. items 1–4). The DIM-stub
references in items 5–8 remain on the existing wallet-stub code path
until a separate Portal+IH workstream picks them up.

The connector configuration is, additionally, **duplicated in four
places**:

- `dataconsumerOne` block in `charts/umbrella/values.yaml` (~line 1086)
- `dataconsumerTwo` block in `charts/umbrella/values.yaml` (~line 1175)
- `tx-data-provider` block in `charts/umbrella/values.yaml` (~line 1340)
- `charts/values-test-data-exchange.yaml` (CI profile, mirror shape)

Any templating refactor must cover all four; otherwise CI drifts from
the adopter profile.

---

## 4. Per-repository work breakdown

### 4.1 `eclipse-edc/Connector` — no changes needed

Wallet-agnostic. Confirmed against the v0.16.0 DCP modules.

### 4.2 `eclipse-edc/IdentityHub` — no changes needed

Upstream is at v0.17.0 and already exposes the stable Identity Admin
API (`/v1/unstable/participants/{ctx}/dids/{did}/endpoints`). OAuth2
auth on the Issuer-Admin API was added in v0.16.0
([eclipse-edc/IdentityHub PR #880](https://github.com/eclipse-edc/IdentityHub/pull/880),
merged 3 Dec 2025); Tractus-X simply consumes it once
`tractusx-identityhub` re-pins from `edc = 0.14.0` to `0.16.0`+
(Section 2.5).

### 4.3 `eclipse-tractusx/tractusx-identityhub` — four tasks

This repository owns the Tractus-X distribution charts for IdentityHub
and IssuerService.

| # | Task | Status | Tracking |
|---|---|---|---|
| 4.3.1 | **Templated ConfigMap names** so two IH instances can coexist in one namespace. | In review (milestone `26.06`). 26 / 28 CI green. | [Issue #257](https://github.com/eclipse-tractusx/tractusx-identityhub/issues/257) / [PR #258](https://github.com/eclipse-tractusx/tractusx-identityhub/pull/258). Bumps charts to **v0.2.1**. |
| 4.3.2 | **Apply the 63-char DNS-label fix** on PR #258 (`printf "%s-config" \| trunc 63 \| trimSuffix "-"`). | Outstanding review comment. | [PR #258](https://github.com/eclipse-tractusx/tractusx-identityhub/pull/258). |
| 4.3.3 | **Extend the `initial-participant` extension** to seed DID-document `services[]` entries (CredentialService, DataService) declaratively from chart values. | Module exists at [`extensions/identityhub/initial-participant`](https://github.com/eclipse-tractusx/tractusx-identityhub/tree/main/extensions/identityhub/initial-participant). Today it seeds *identity* (OAuth client + super-user X-Api-Key) but **not** `services[]`. Schema extension required. | New issue + PR. |
| 4.3.4 | **Confirm `tractusx-issuerservice` and `tractusx-issuerservice-memory` chart variants** are published to `https://eclipse-tractusx.github.io/charts/dev`. | To verify via `helm search repo tractusx/`. | Release-pipeline check. |

The IH chart's runtime endpoints (anchored against
[`charts/tractusx-identityhub/values.yaml`](https://github.com/eclipse-tractusx/tractusx-identityhub/blob/main/charts/tractusx-identityhub/values.yaml)
on `main`):

| Endpoint | Port | Path | Auth |
|---|---|---|---|
| Health | 8081 | `/api` | none |
| Identity Admin API | 8082 | `/api/identity` | `X-Api-Key` |
| Credentials (DCP Presentation) | 8083 | `/api/credentials` | DCP token |
| DID resolution | 8084 | `/` | none |
| STS Accounts admin | 8085 | `/api/accounts` | `X-Api-Key` |
| Version (well-known) | 8086 | `/.well-known/api` | none |
| STS token issuance | 8087 | `/api/sts` | per-token |

A companion module, [`extensions/seed/super-user`](https://github.com/eclipse-tractusx/tractusx-identityhub/tree/main/extensions/seed/super-user),
already seeds the super-user credential at install time, which keeps
the umbrella post-install Job (Section 5.4) focused on per-participant work.

> Note on chart-key naming: the IH chart's initial-participant block is
> still keyed `iatp:`. The connector chart was renamed `iatp` → `dcp` in
> [`tractusx-edc#2742`](https://github.com/eclipse-tractusx/tractusx-edc/pull/2742).
> The two repositories will diverge on this naming until a follow-up
> rename in IH; we treat the current `iatp:` key as authoritative for
> v1.

### 4.4 `eclipse-tractusx/tractusx-edc` — chart migration only

| # | Task | Status |
|---|---|---|
| 4.4.1 | **`iatp` → `dcp` chart-values rename** consumed downstream. | Already on `main` via [PR #2742](https://github.com/eclipse-tractusx/tractusx-edc/pull/2742) (Dec 2025). Breaking for any chart consumer; the umbrella has not yet absorbed it. |
| 4.4.2 | **`participant.id` schema split** into `{id (DID), bpnl, contextId (UUID)}`. | Same PR #2742. Equally breaking for the umbrella. |
| 4.4.3 | **`DidDocumentServiceIdentityHubClient`** SPI implementation (parallel to the existing DIM client). | Reference implementation lives in [`Federity-X/public-tractusx-edc#7`](https://github.com/Federity-X/public-tractusx-edc/pull/7) → [`#8`](https://github.com/Federity-X/public-tractusx-edc/pull/8) → `dcp-v2` branch. Issue [`tractusx-edc#2678`](https://github.com/eclipse-tractusx/tractusx-edc/issues/2678) tracks upstream landing; explicitly deferred to **R26.06** by the EDC Board (see [`sig-release#1609`](https://github.com/eclipse-tractusx/sig-release/issues/1609)) pending the IH 0.16.0 bump. The proposed runtime config introduces three new keys — `tx.edc.ih.identity.api.url`, `tx.edc.ih.participant.context.id`, `tx.edc.ih.identity.api.key.alias` — and the IH client activates **only when `tx.edc.iam.sts.dim.url` is unset** (mutually exclusive with the DIM client). |

Tasks 4.4.1 and 4.4.2 are **prerequisites for any tractusx-connector
chart bump** in the umbrella — they are not optional. Task 4.4.3 is
**not on the v1 critical path**: Section 5.3 below describes the
chart-time-seeding alternative that avoids needing it.

### 4.5 `eclipse-tractusx/bpn-did-resolution-service` — done

- Release **0.6.0** with EDC 0.16.0 and Postgres 18 — already published.
  Subsequent maintenance kept the chart aligned with the connector's
  cloud-pirates Helm-chart version
  ([PR #400](https://github.com/eclipse-tractusx/bpn-did-resolution-service/pull/400),
  merged 25 Mar 2026).
- Replaces the `0.7.0-SNAPSHOT` workaround used in
  [`tractus-x-umbrella PR #396`](https://github.com/eclipse-tractusx/tractus-x-umbrella/pull/396).
- **Both** `bdrs-server` and `bdrs-server-memory` charts expose only:
  `endpoints.management` on `:8081 /api/management`,
  `endpoints.directory` on `:8082 /api/directory`,
  `trustedIssuers: []`. There is **no `initialMappings` /
  `seed` / `bootstrap` block.** BPN→DID mappings must be loaded via
  the management API after install (this drives Section 5.4).

### 4.6 `eclipse-tractusx/portal-backend` — out of scope for v1

[`portal-backend#1422`](https://github.com/eclipse-tractusx/portal-backend/pull/1422)
"feat: bring your own wallet" was merged on **7 Jan 2026** (milestone
`26.03`, closes [`sig-release#1160`](https://github.com/eclipse-tractusx/sig-release/issues/1160)).
The companion frontend PR
[`portal-frontend-registration#407`](https://github.com/eclipse-tractusx/portal-frontend-registration/pull/407)
is open.

The umbrella's `charts/umbrella/values.yaml` line 109 already exposes
`portal.backend.useDimWallet: true`. Setting it to `false` and
re-pointing onboarding URLs will be the v2 work to enable Portal +
IdentityHub end-to-end. v1 leaves Portal on the wallet-stub path; the
IH switch is **scoped to the data-exchange profile**.

---

## 5. Umbrella deliverables (the integration work itself)

These are all in `eclipse-tractusx/tractus-x-umbrella` and constitute
the actual submission of this plan.

### 5.1 Identity-provider feature flag + conditional dependency

`charts/identity-and-trust-bundle/Chart.yaml` (currently v1.1.3, only
depends on `ssi-dim-wallet-stub` 0.1.17) gains conditional dependencies:

```yaml
dependencies:
  - name: ssi-dim-wallet-stub
    version: 0.1.17
    repository: https://eclipse-tractusx.github.io/charts/dev
    condition: ssi-dim-wallet-stub.enabled
  - name: tractusx-identityhub
    version: ">=0.2.1"   # gated on 4.3.1 + 4.3.2
    repository: https://eclipse-tractusx.github.io/charts/dev
    condition: tractusx-identityhub.enabled
  - name: tractusx-issuerservice
    version: ">=0.2.1"   # gated on 4.3.4
    repository: https://eclipse-tractusx.github.io/charts/dev
    condition: tractusx-issuerservice.enabled
```

The umbrella `values.yaml` exposes a single switch:

```yaml
identityProvider:
  type: wallet-stub        # wallet-stub | identityhub
ssi-dim-wallet-stub:
  enabled: '{{ eq .Values.identityProvider.type "wallet-stub" }}'
tractusx-identityhub:
  enabled: '{{ eq .Values.identityProvider.type "identityhub" }}'
```

This contrasts with [`tractus-x-umbrella PR #396`](https://github.com/eclipse-tractusx/tractus-x-umbrella/pull/396),
which disables the stub unconditionally. A feature flag keeps every
existing wallet-stub adopter on a known-good code path.

### 5.2 Connector schema migration (`iatp` → `dcp`)

This is **independent** of IdentityHub but must land first; without it
no `tractusx-connector` chart bump can be consumed.

Affected files:

- `charts/umbrella/values.yaml` — three connector blocks
  (`dataconsumerOne`, `dataconsumerTwo`, `tx-data-provider`).
- `charts/dataspace-connector-bundle/values.yaml`.
- `charts/values-test-data-exchange.yaml`.

Mechanical changes:

| Old | New |
|---|---|
| `iatp:` | `dcp:` |
| `iatp.sts.dim.url` | `dcp.sts.div.url` |
| `iatp.sts.oauth.{token_url, client.id, client.secret_alias}` | `dcp.sts.oauth.{token_url, client.id, client.secret_alias}` |
| `iatp.trustedIssuers[]` | `dcp.trustedIssuers[{id, supportedTypes}]` |
| `participant.id: BPNL...` (BPN string) | `participant.id: did:web:...` (DID), `participant.bpnl: BPNL...`, `participant.contextId: <uuid>` |

A new `dcp.didService.selfRegistration.enabled: false` toggle exists in
the connector chart since [`tractusx-edc PR #2742`](https://github.com/eclipse-tractusx/tractusx-edc/pull/2742);
it is the chart-side hook for
[`tractusx-edc issue #2678`](https://github.com/eclipse-tractusx/tractusx-edc/issues/2678).
The IH-side runtime implementation has not landed in `tractusx-edc`
`main`, so we leave this **`false` in v1** (a `true` value has no
effect without the #2678 implementation).

### 5.3 Templated `_dcp.tpl` partial

The four duplicated blocks identified in Section 3 collapse into one Helm
partial keyed on participant (`bpnl`, `host`, `contextId`) and
`identityProvider.type`. The partial emits either the legacy
`iatp:`-shaped block (stub mode) or the new `dcp:`-shaped block (IH
mode) with the right CredentialService URL, BDRS URL, trustedIssuers
list, and STS configuration.

This is a pure refactor. It has no functional impact on the existing
wallet-stub profile when covered by the existing
`values-test-data-exchange.yaml` CI run.

### 5.4 Post-install Job for BPN/DID seeding and credential issuance

Modeled on the existing
[`charts/tx-data-provider/templates/post-install-job-upload-testdata.yaml`](../../../charts/tx-data-provider/templates/post-install-job-upload-testdata.yaml)
(idempotent, ConfigMap-mounted, re-runnable on `helm upgrade`). One
Job, executing in this order:

1. **BDRS** — `POST /api/management/bpn-directory` to
   `bdrs-server-memory:8081` for every participant's BPN→DID mapping.
   In the `-memory` variant the management auth uses
   `authKey: "password"` (plain string), so no Vault dependency.
2. **IdentityHub service entries** — `POST /v1/unstable/participants/{contextId}/dids/{base64url-did}/endpoints?autoPublish=true`
   to each IH `:8082/api/identity` with `X-Api-Key`, registering the
   DSP `DataService` and `CredentialService` URLs. The `{did}` path
   parameter is base64url-encoded; the `Service` body carries `id`,
   `type` (`CredentialService` / `DataService`), and `serviceEndpoint`.
   (This step disappears once Section 4.3.3 lands.)
3. **IssuerService bootstrap** — participant + attestation +
   credential-definition setup for the four VC types
   (`MembershipCredential`, `BpnCredential`, `UsagePurposeCredential`,
   `DataExchangeGovernanceCredential`).
4. **Credential issuance** — one issuance request per holder per VC type.

Super-user bootstrap inside IH does **not** belong in this Job —
the upstream `extensions/seed/super-user` module handles it at
install time.

### 5.5 Conditional Vault `postStart` block

`charts/dataspace-connector-bundle/values.yaml` today seeds Vault with
DIM-OAuth secrets:

```yaml
vault.server.postStart:
  - sleep 5
  - /bin/vault kv put secret/client-secret content=...
  - /bin/vault kv put secret/aesKey       content=...
```

For IdentityHub mode the same Vault must instead hold:

| Alias | Purpose | Algorithm | Lifecycle |
|---|---|---|---|
| `tokenSignerPrivateKey` | EC JWK used by the participant's signer (alias already declared at [`charts/dataspace-connector-bundle/values.yaml`](../../../charts/dataspace-connector-bundle/values.yaml) line 135 — only the `postStart` seed is missing) | EC P-256 (`alg=ES256`); v1 default. Ed25519 (`EdDSA`) optional once IH chart `signer.algorithm` value supports it. | generated by post-install Job; rotation = re-run Job, IH `verificationMethod` rewritten via `/v1/unstable/participants/{ctx}/keys`. v1 has no automatic rotation. |
| `tokenSignerPublicKey` | Public JWK whose `kid` MUST match the `did:web` Document `verificationMethod[0].publicKeyJwk.kid` (see Section 2.1 invariant 2). | derived from private | bundled into the DID Document at seed time by the IH `initial-participant` extension (Section 4.3.3). |
| `identityhub-api-key` | X-Api-Key consumed by the post-install Job (Section 5.4) and by the `DidDocumentServiceIdentityHubClient` if v2 adopts it (Section 4.4.3). | n/a (opaque) | seeded by `postStart`; no rotation in v1. |

Key-generation locus is the **post-install Job** (Section 5.4), not the
Vault `postStart` block. `postStart` only runs Vault-CLI commands; key
generation belongs in the Job's container so the umbrella values stay
declarative and reproducible. The Job:

1. Generates an EC P-256 keypair (e.g. `openssl ecparam -genkey`),
   converts to JWK with a deterministic `kid` (`key-1`).
2. Writes the private JWK to `secret/<participant>/tokenSignerPrivateKey`.
3. Hands the public JWK to the IH Identity Admin API so it lands in
   the DID Document `verificationMethod`.

Branch the existing `postStart` block on `identityProvider.type` only
for the `identityhub-api-key` alias (a static value safe to template).

### 5.6 New adopter profile + CI profile

- `charts/umbrella/values-adopter-data-exchange-identityhub.yaml` —
  adopter-facing profile, modeled on the existing
  `values-adopter-data-exchange.yaml`. Sets
  `identityProvider.type: identityhub` and uses YAML anchors to remove
  the per-participant duplication that
  [`tractus-x-umbrella PR #396`](https://github.com/eclipse-tractusx/tractus-x-umbrella/pull/396)
  carries.
- `charts/values-test-data-exchange-identityhub.yaml` — CI mirror
  profile, used by a new step in
  [`.github/workflows/helm-checks.yaml`](../../../.github/workflows/helm-checks.yaml):
  `helm install umbrella -f charts/values-test-data-exchange-identityhub.yaml --wait --wait-for-jobs`
  followed by a smoke probe of one DSP `catalog/request`. **The
  existing `values-test-data-exchange.yaml` step is left untouched** so
  the wallet-stub legacy path remains a CI gate.

### 5.7 `did:web` over HTTP in-cluster

`did:web:host:bpn` resolves over HTTPS by default. The umbrella runs
in-cluster with self-signed TLS at best (`values-tls.yaml`). The
connector already uses `EDC_IAM_DID_WEB_USE_HTTPS: false` (9 occurrences
in `charts/`); the equivalent must be set in IH mode on:

- the connector control-plane and data-plane (`EDC_IAM_DID_WEB_USE_HTTPS: false`),
- the IssuerService (resolves holder DIDs during issuance — same env var),
- the IH itself, via the chart key `didweb.https: false` (the IH chart
  exposes this as a top-level toggle rather than an env var).

The IH chart's ingress must serve `/{base64url-did}/did.json` on the
*same* hostname encoded into the DID.
[`tractus-x-umbrella PR #396`](https://github.com/eclipse-tractusx/tractus-x-umbrella/pull/396)
has a working example.

### 5.8 Trusted-issuers list

`iatp.trustedIssuers` (today, per connector block) is hard-coded to one
entry: `did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003CRHK`. In IH
mode this becomes `did:web:{issuerservice-host}:BPNL00000003CRHK`
(or whichever BPN runs `tractusx-issuerservice`). The list is promoted
to a **top-level** key in the umbrella values, fanned out by the
`_dcp.tpl` partial — not duplicated by hand.

### 5.9 Documentation

A new section in
[`docs/user/common/guides/`](../../user/common/guides/) covering:

- The `identityProvider.type` switch and its consequences (Portal stack
  remains stub-backed in v1).
- Pre-flight check: confirm `tractusx-identityhub` ≥ 0.2.1 is in the
  chart registry.
- Post-install Job behaviour and re-run semantics.

Cross-link from the existing development setup guide.

---

## 6. Design decisions and the STS question

Two architectural choices in this plan deserve explicit justification.

### 6.1 STS path

The connector mints SI-tokens at every contract / transfer step via a
Secure Token Service. With DIM the connector calls
`POST /api/sts` on the DIM wallet. Three options exist for IdentityHub:

| Option | Mechanics | v1 fit |
|---|---|---|
| **A — Embedded STS** | Connector signs SI-tokens locally with a vault-stored JWK using eclipse-edc's `sts-embedded` runtime. | The `tractusx-connector` chart `main` does **not** expose `dcp.sts.embedded` keys today (only `dcp.sts.div`). Would require either an upstream chart PR or `controlplane.env` overrides whose support depends on which STS modules the runtime image bundles. **Technical validation required.** |
| **B — IH STS at `:8087/api/sts`** | Re-point the connector's STS URL to the IH pod. | IH does ship STS at port 8087, but the request shape (`RemoteSecureTokenService` signed `client_assertion`) differs from the DIM/DIV shape (OAuth2-style). A direct re-point fails signature/shape validation without an adapter. **Technical validation required (source inspection of `RemoteSecureTokenService`).** |
| **C — Continue calling DIM STS** | Leave `dcp.sts.div.url` pointing at the wallet stub's `/api/sts` even when IH is enabled. | Defeats the point of replacing the stub for v1. ❌ Not viable. |

**Recommendation.** Schedule a focused validation against
`tractusx-edc` `RemoteSecureTokenService` to determine whether option B
works as-is. If yes, v1 ships option B. If no, v1 ships option A.

**Plan-A sketch** (sts-embedded fallback). The eclipse-edc
`sts-embedded` runtime expects the controlplane to load a signer JWK
and to mint SI-tokens locally. With the `tokenSignerPrivateKey` already
staged in Vault (Section 5.5), the connector controlplane env in IH
mode would carry:

```yaml
controlplane:
  env:
    EDC_IAM_STS_PRIVATEKEY_ALIAS: tokenSignerPrivateKey
    EDC_IAM_STS_PUBLICKEY_ID:     "did:web:...:BPNL...#key-1"
    EDC_IAM_ISSUER_ID:            "did:web:...:BPNL..."
    # and dcp.sts.div.url left UNSET so the embedded service is selected
```

Availability of these keys depends on whether the `tractusx-connector`
image bundles `eclipse-edc` modules `sts-core` + `sts-api`. If yes, the
chart needs only env-var overrides (no chart PR). If not, v1 ships an
upstream `tractusx-edc` chart PR exposing `dcp.sts.embedded` and
including the modules in the runtime image.

This is the **single most important pre-flight check** for the whole
plan. It does not block planning, but it determines whether Section 5.5's
Vault block holds the JWK or only the IH X-Api-Key.

### 6.2 DID-document service registration

Two options:

- **Declarative seeding (chosen)** — extend the IH `initial-participant`
  module so chart values populate `services[]` on the seeded DID
  Document. The connector never mutates its DID at runtime;
  `dcp.didService.selfRegistration.enabled` stays `false`. Requires
  Section 4.3.3, plus the Section 5.4 fallback Job until 4.3.3 ships.
- **Runtime registration (deferred)** — adopt the
  `DidDocumentServiceIdentityHubClient` SPI from
  [`tractusx-edc#2678`](https://github.com/eclipse-tractusx/tractusx-edc/issues/2678)
  / [`Federity-X PR #8`](https://github.com/Federity-X/public-tractusx-edc/pull/8).
  This introduces a breaking config knob
  (`tx.edc.did.service.client.type=dim|identityhub`) for existing DIM
  adopters. The EDC Board has explicitly deferred upstream landing to
  R26.06 pending the IH 0.16.0 bump, so this option is **not on the v1
  critical path** — adopt it as v2 when IH 0.16.0 lands in
  `tractusx-edc`.

Declarative seeding is preferred because it keeps the umbrella as a
GitOps artefact and avoids tying v1 to an externally-scheduled R26.06
deliverable.

---

## 7. Sequencing and critical path

```
[ tractusx-identityhub ]                      [ bpn-did-resolution-service ]
   PR #258 templated CMs        🟡                   v0.6.0 released         ✅
   63-char DNS-label fix        🟡                   (memory chart, no
   initial-participant +                              chart-time seeding)
       services[] schema PR     🟡 NEW
   chart publish v0.2.1         🟡

                              ▼

                       [ tractusx-edc ]
                          iatp → dcp rename (PR #2742)    ✅ on main
                          chart consumed downstream       🔴 (Section 5.2)

                              ▼

                  [ tractus-x-umbrella  (this repo) ]
                     Section 5.1  feature flag + dependency     🔴
                     Section 5.2  iatp → dcp migration          🔴 prerequisite
                     Section 5.3  _dcp.tpl partial              🔴
                     Section 5.4  post-install Job              🔴
                     Section 5.5  conditional Vault postStart   🔴
                     Section 5.6  adopter + CI profiles         🔴
                     Section 5.7  did:web HTTP flag plumbing    🔴
                     Section 5.8  trustedIssuers top-level      🔴
                     Section 5.9  documentation                 🔴
```

Out-of-band:

- [`tractusx-edc issue #2678`](https://github.com/eclipse-tractusx/tractusx-edc/issues/2678)
  — R26.06 deliverable, **deferred to v2**, not a v1 dependency.
- Portal-backend BYOW — already merged
  ([`portal-backend PR #1422`](https://github.com/eclipse-tractusx/portal-backend/pull/1422)),
  consumed in a v2 Portal+IH integration workstream.

---

## 8. Risk register

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| R1 | [`tractusx-identityhub PR #258`](https://github.com/eclipse-tractusx/tractusx-identityhub/pull/258) stalls again in review (DNS-label fix iteration). | Medium | Pick up the suggested `printf \| trunc 63 \| trimSuffix "-"` helper directly. The change is mechanical. |
| R2 | The `initial-participant` `services[]` schema extension (Section 4.3.3) is rejected upstream or slips. | Medium | The Section 5.4 Job is the contingency: it calls the IH Identity Admin API directly (`POST /v1/unstable/participants/{contextId}/dids/{base64url-did}/endpoints?autoPublish=true`). The Job is required regardless for credential issuance, so the marginal cost is small. |
| R3 | STS validation (Section 6.1) shows option B unviable **and** option A requires a chart PR. | Medium | Sequence the validation before finalizing Section 5.5. If both are blocked, v1 contributes the `dcp.sts.embedded` chart block to `tractusx-edc` via a small upstream PR. |
| R4 | The `iatp → dcp` migration breaks [`tractus-x-umbrella PR #396`](https://github.com/eclipse-tractusx/tractus-x-umbrella/pull/396) and other in-flight branches. | High | Communicate the migration explicitly. Coordinate with [`@AYaoZhan`](https://github.com/AYaoZhan) (who owns [`tractusx-identityhub PR #258`](https://github.com/eclipse-tractusx/tractusx-identityhub/pull/258), the IH `initial-participant` refactor, and umbrella PR #396). |
| R5 | IH chart's templated ConfigMap names truncate and overlap across two participants. | Low (after R1) | Add a `helm template`-based CI lint in this repo that asserts uniqueness of all rendered ConfigMap `metadata.name` values across a two-participant install. |
| R6 | `did:web` resolution fails because IH ingress hostname does not match the DID host segment. | Medium | Reuse the ingress shape verified in [`tractus-x-umbrella PR #396`](https://github.com/eclipse-tractusx/tractus-x-umbrella/pull/396); cover with a CI smoke probe in Section 5.6. |
| R7 | Adopters silently mix wallet-stub and IH modes (e.g. half the participants on each). | Low | Validate `identityProvider.type` consistency in the `_dcp.tpl` partial; fail `helm template` early. |

---

## 9. Open questions / validation checks

These do not block the plan, but they sharpen specific deliverables.

1. **STS validation.** Does eclipse-edc's `RemoteSecureTokenService` accept
   the IH `:8087/api/sts` request shape, or does it strictly require
  the DIV/DIM OAuth2 form? This determines whether
   Section 6.1 is option A or option B.
2. **Chart-registry publication.**
   `helm search repo tractusx/tractusx-identityhub` and
   `helm search repo tractusx/tractusx-issuerservice`. Confirms Section 4.3.4
   is satisfied without an additional pipeline change.
3. **`initial-participant` services-schema ownership.** File the
   Section 4.3.3 schema-extension issue against `tractusx-identityhub` so it is
   visible to `AYaoZhan` (current module owner). If accepted, the Section 5.4
   Job's IH-endpoint step disappears.
4. **Portal 26.03 chart release date.** Confirms when the v2 Portal+IH
   workstream can begin. Tracked in
   [`sig-release#1160`](https://github.com/eclipse-tractusx/sig-release/issues/1160).

---

## 10. Recommendation

1. **Approve scope as data-exchange-only for v1.** The Portal /
   onboarding stack stays on the wallet stub; Portal+IH is a v2
   workstream that depends on the already-merged
   [`portal-backend PR #1422`](https://github.com/eclipse-tractusx/portal-backend/pull/1422)
   plus a Portal chart 26.03 bump.
2. **Land Section 5.2 (`iatp → dcp` migration) first**, independent of the
   IdentityHub work. It is a prerequisite for *any* `tractusx-connector`
   chart bump and is otherwise risk-free.
3. **Sequence remaining work behind
   [`tractusx-identityhub PR #258`](https://github.com/eclipse-tractusx/tractusx-identityhub/pull/258).**
   Once `tractusx-identityhub` 0.2.1 publishes, Sections 5.1 and 5.3
   through 5.9 are unblocked in parallel.
4. **Run the Section 6.1 STS validation now.** It does not block planning, but it
   pins down the shape of Section 5.5 and the upstream `tractusx-edc` chart
   work (if any).
5. **Treat [`tractusx-edc issue #2678`](https://github.com/eclipse-tractusx/tractusx-edc/issues/2678)
   as v2 / R26.06 work.** The chart toggle exists today; the IH-side
   runtime implementation is upstream-deferred and would, if landed
   early, force a breaking change on every existing DIM adopter.
6. **Coordinate with [`@AYaoZhan`](https://github.com/AYaoZhan) and
   [`@wahidulazam`](https://github.com/wahidulazam).** They own the
   reference implementations across `tractusx-identityhub`,
   [`tractus-x-umbrella PR #396`](https://github.com/eclipse-tractusx/tractus-x-umbrella/pull/396),
   and the
   [`Federity-X dcp-v2` branch](https://github.com/Federity-X/public-tractusx-edc/tree/dcp-v2).
   Aligning with their work avoids parallel implementations.

This plan is anchored against the current `main` branches of
[`tractusx-identityhub`](https://github.com/eclipse-tractusx/tractusx-identityhub),
[`tractusx-edc`](https://github.com/eclipse-tractusx/tractusx-edc),
[`bpn-did-resolution-service`](https://github.com/eclipse-tractusx/bpn-did-resolution-service),
[`portal-backend`](https://github.com/eclipse-tractusx/portal-backend),
and [`tractus-x-umbrella`](https://github.com/eclipse-tractusx/tractus-x-umbrella),
plus the following primary references:

- [`tractusx-identityhub PR #258`](https://github.com/eclipse-tractusx/tractusx-identityhub/pull/258)
  — templated ConfigMap names, charts to v0.2.1.
- [`tractusx-identityhub Issue #257`](https://github.com/eclipse-tractusx/tractusx-identityhub/issues/257)
  — companion issue for PR #258.
- [`tractusx-edc PR #2742`](https://github.com/eclipse-tractusx/tractusx-edc/pull/2742)
  — `iatp` → `dcp` chart-values rename and `participant.id` schema split.
- [`tractusx-edc Issue #2678`](https://github.com/eclipse-tractusx/tractusx-edc/issues/2678)
  — `DidDocumentServiceIdentityHubClient` SPI implementation, deferred
  to R26.06.
- [`tractus-x-umbrella PR #396`](https://github.com/eclipse-tractusx/tractus-x-umbrella/pull/396)
  — first Helm-layer integration attempt.
- [`bpn-did-resolution-service PR #400`](https://github.com/eclipse-tractusx/bpn-did-resolution-service/pull/400)
  — cloud-pirates Helm-chart alignment (post-0.6.0 maintenance).
- [`portal-backend PR #1422`](https://github.com/eclipse-tractusx/portal-backend/pull/1422)
  — Bring-Your-Own-Wallet onboarding flow (merged 7 Jan 2026).
- [`portal-frontend-registration PR #407`](https://github.com/eclipse-tractusx/portal-frontend-registration/pull/407)
  — companion frontend BYOW step.
- [`eclipse-edc/IdentityHub PR #880`](https://github.com/eclipse-edc/IdentityHub/pull/880)
  — OAuth2 on the Issuer-Admin API (merged 3 Dec 2025).
- [`sig-release Issue #1609`](https://github.com/eclipse-tractusx/sig-release/issues/1609)
  — R26.06 IH + Connector bundle.
- [`sig-release Issue #1160`](https://github.com/eclipse-tractusx/sig-release/issues/1160)
  — onboarding-process & DCP-issuance flow for BYOW.
- [`Federity-X/public-tractusx-edc#dcp-v2`](https://github.com/Federity-X/public-tractusx-edc/tree/dcp-v2)
  — end-to-end Docker Compose reference flow.
- [`Federity-X PR #8`](https://github.com/Federity-X/public-tractusx-edc/pull/8)
  — IdentityHub `DidDocumentServiceClient` reference implementation.
