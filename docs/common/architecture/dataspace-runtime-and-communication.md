# Dataspace Runtime & Component Communication

> **Companion to [ECOSYSTEM-GUIDE.md](../../../ECOSYSTEM-GUIDE.md).** That guide is the
> structural overview (what each component is, the Helm layering). **This** document is the
> runtime deep-dive: **who talks to whom, over which protocol, and how a dataspace is
> provisioned and operated.** Scope = the **dataspace core** (the components that actually
> run a data transfer). Both wallet models — `ssi-dim-wallet-stub` and IdentityHub — are
> covered side-by-side.

**Version note:** the connector is `tractusx/edc-*-hashicorp-vault:0.13.0-SNAPSHOT`
(**EDC 0.17.0**, built from `tractusx-edc` `main`); IdentityHub + IssuerService are the
0.17.0 line (PR #309). Where ECOSYSTEM-GUIDE.md still says `0.13.0-rc2`/EDC 0.16.0 it is
dated; this doc reflects the current stack.

---

## 1. Participants & roles

A dataspace is a set of **participants**, each with two identities:

- **BPN** (Business Partner Number) — the legal/business identity, e.g. `BPNL00000003AYRE`.
- **DID** (`did:web:…`) — the cryptographic identity that resolves to a DID document
  (public keys + service endpoints). The wallet owns the DID's keys.

The umbrella models one **provider** + up to two **consumers**, plus one **operator** who is
the dataspace's **trusted issuer**. Single source of truth:
`charts/umbrella/values.yaml` → `wallet.participants` (consumed by
`templates/_wallet-derive.tpl`).

| Participant key | Role | BPN | Purpose |
|---|---|---|---|
| `operator` | operator / **issuer** | `BPNL00000003CRHK` | Runs the IssuerService; issues every participant's credentials; its DID is the **trusted issuer** every connector verifies against |
| `provider` | provider | `BPNL00000003AYRE` | Shares data (assets → DTR twins → submodels) |
| `consumer1` | consumer | `BPNL00000003AZQP` | Consumes data |
| `consumer2` | consumer | `BPNL00000003AVTH` | Second consumer (idle in the 2-participant profile) |

Identity derivation (from `_wallet-derive.tpl`):
- **participantId** = `<role>-<bpn-lowercased>` (e.g. `provider-bpnl00000003ayre`) — the
  IdentityHub ParticipantContext id.
- **DID** = `did:web:<wallet-host>:<BPN>` — stub uses `ssi-dim-wallet-stub.tx.test`; IH
  per-participant uses `ih-<role>.tx.test`; IH shared uses one host for all.
- **CredentialService URL** = `<ih-base>/api/credentials/v1/participants/<base64url(participantId)>`.
- **STS URL** = `<ih-base>/api/sts`.
- **Issuer DID** = `did:web:<issuerServiceHost>:<operatorBpn>` (IH) or `<stub-didBase>:<operatorBpn>` (stub).

---

## 2. Component inventory (dataspace core)

| Component | Role | Key endpoints (internal ⁄ ingress) | Wallet mode |
|---|---|---|---|
| **EDC Control Plane** (per participant) | Contracting brain: catalog, negotiation, transfer, policy, EDR | Management API `…/management/v3`; DSP protocol endpoint; health `/api/check/health` | both |
| **EDC Data Plane** (per participant) | Moves bytes; proxies to backends | Public API `/api/public` | both |
| **Connector Postgres** (per participant) | Control/data-plane state (contracts, EDRs) | `5432` | both |
| **HashiCorp Vault** (per connector) | Secrets: `edc-wallet-secret` (STS client secret), token-signing keys | `:8200`, KV-v2 `secret/` | both |
| **ssi-dim-wallet-stub** | Mock wallet — fakes STS + CredentialService + VCs for all BPNs | `/api/sts`, `/api/…` (credential service), `/oauth/token` | stub |
| **IdentityHub** (per participant, or one shared) | Real DCP wallet: 3 services — **Identity API** `:8081` (admin ParticipantContexts), **Credential Service** `:8082` (holds VCs, answers PresentationQuery), **STS** (mints SI tokens) | `/api/identity`, `/api/credentials`, `/api/sts` | identityHub |
| **IssuerService** | Trusted issuer (operator): registers holders, issues/offers VCs, revocation | Identity `:8087`, Issuer-Admin `:8086` `/api/admin`, Issuance `:8082` (CIP) | identityHub |
| **BDRS Server** | BPN↔DID directory (who is which DID) | `:8081` `/api/management/bpn-directory` (seed) + directory query (connector) | both |
| **Digital Twin Registry (DTR)** | AAS registry: shell descriptors → submodel endpoints | `:8080` `/api/v3/shell-descriptors` | provider only |
| **Submodel backend** (`simple-data-backend`) | Serves the actual submodel JSON | HTTP data endpoint | provider only |

> **Port note:** the IdentityHub ports above are the **in-memory** variant (`docker-identityhub-memory`): Identity `8081`, Credential `8082`. The **PostgreSQL** IdentityHub variant shifts them (Identity `8082`, Credential `8083`, DID `8084`, STS `8087`). The IssuerService uses Identity `8087`, Issuer-Admin `8086`, Issuance `8082`. Treat the per-profile `wallet.identityHub…ports` map (surfaced via `_wallet-derive.tpl`) as the source of truth, not these numbers.

---

## 3. Component-communication matrix

The interactions that make a transfer happen. "CS" = Credential Service; "SI token" =
Self-Issued token.

| # | Caller → Callee | Protocol | Endpoint / API | Purpose |
|---|---|---|---|---|
| 1 | Connector CP → its **Vault** | HTTP (KV-v2) | `secret/data/edc-wallet-secret`, signing keys | Read STS client secret + token-signing keys at boot & per request |
| 2 | Consumer CP → its **STS** (stub `/api/sts` or IH `/api/sts`) | OAuth2 / DCP | `POST /api/sts` | Mint a **SI token** carrying an embedded, scoped access grant (Membership/Bpn/DEG) |
| 3 | Consumer CP → **Provider CP** | **DSP** (Dataspace Protocol) | Catalog request, negotiation, transfer (via provider DSP endpoint) | Request catalog / negotiate contract / start transfer, presenting the SI token |
| 4 | Provider CP → **Consumer CS** (stub or IH `:8082`) | **DCP** | `POST /api/credentials/…/presentations/query` | "Query-back": ask the consumer's wallet for a **Verifiable Presentation** of the granted scopes |
| 5 | Provider CP → **trusted-issuer DID** | `did:web` resolution (HTTPS/HTTP) | `GET …/did.json` | Resolve the issuer's public key to verify the VP's signatures |
| 6 | Provider CP → **BDRS** | HTTP | directory resolve (`bdrsClient.resolveBpn(did)`) | Map consumer DID ↔ BPN on `ContractNegotiationFinalized` (needed for the transfer) |
| 7 | Consumer DP → **Provider DP** | HTTP (EDR-authenticated) | `GET /api/public` | Pull the asset bytes using the EDR endpoint + token |
| 8 | Provider DP → **Submodel backend / DTR** | HTTP | backend data URL / `/api/v3/shell-descriptors` | The proxied target the data plane serves |
| 9 | Consumer (panel/agent) → **DTR** (through the provider EDR proxy) | HTTP | `GET /api/v3/shell-descriptors?limit&cursor&sortDirection` | Discover digital twins → submodel endpoints |
| 10 | **IH-seed Job** → **IssuerService** Issuer-Admin | HTTP | `POST …/participants/{ctx}/holders`, `…/credentials/offer` | Register each participant as a holder; issue/offer their VCs |
| 11 | **IH-seed Job** → **IdentityHub** Identity API `:8081` | HTTP | `…/api/identity/v1alpha/participants/…` | Create the ParticipantContext + scrape the STS client secret → Vault (row 1) |
| 12 | **IdentityHub CS** → **IssuerService** Issuance `:8082` | **DCP CIP** | CredentialRequest / status | Holder pulls the offered credential (holder-pull) |
| 13 | **bdrs-setup Job** → **BDRS** | HTTP | `POST /api/management/bpn-directory` (x-api-key) | Seed the BPN→DID directory from `bpnList` |

**Stub vs IH per row:** rows 2 & 4 hit the **one stub service** for every BPN in stub mode;
in IH mode each participant has its **own** STS + CS (its IdentityHub). Rows 10–12 exist
**only** in IH mode (the stub fabricates credentials, so no issuance happens).

---

## 4. Runtime sequence flows

### Flow A — Identity & credential issuance (bootstrap)
**Stub:** nothing to issue — the stub answers any STS/CS call with fabricated tokens/VCs.
**IdentityHub:** the seed Job provisions real credentials before any transfer:
```
IH-seed Job                 IdentityHub (per participant)        IssuerService (operator)
   │  create ParticipantContext ─────────►│                              │
   │◄── 201 { STS client secret } ────────│                              │
   │  write secret → connector Vault       │                              │
   │  register holder (did) ──────────────────────────────────────────►  │
   │  trigger CredentialOffer ─────────────────────────────────────────► │
   │                                       │◄── DCP CredentialOffer ──────│
   │                                       │  CredentialRequest (CIP) ───►│
   │                                       │◄── VC (Membership/Bpn/DEG/FA)│  (holder now holds VCs)
```
Result: each IdentityHub holds `MembershipCredential`, `BpnCredential`,
`DataExchangeGovernanceCredential`, `FrameworkAgreementCredential`.

### Flow B — DCP-authenticated catalog (the trust handshake)
```
Consumer CP                          Provider CP                      Consumer CS (wallet)
   │ mint SI token @ own STS          │                                  │
   │  (embeds scope grant: Membership,│                                  │
   │   Bpn, DataExchangeGovernance)   │                                  │
   │ Catalog request + SI token ─────►│                                  │
   │                                  │ verify SI token                  │
   │                                  │ query-back: PresentationQuery ──►│
   │                                  │◄──────── Verifiable Presentation ─│
   │                                  │ verify VP sigs vs trusted-issuer DID (resolve did:web)
   │                                  │ evaluate ACCESS policy on VC claims
   │◄── Catalog (offers) ─────────────│   (empty if a required VC/claim is missing)
```
**Gotcha:** the verifier requires **Membership + Bpn + DataExchangeGovernance**; a missing
one → **401** and an empty catalog. Thin credential claims (no `bpn`, no `contractVersion`)
pass presence checks but fail value checks — see §8.

### Flow C — Contract negotiation → BPN resolution
```
Consumer CP ── DSP negotiate ──► Provider CP
   Provider evaluates USAGE/contract policy (FrameworkAgreement eq DataExchangeGovernance:1.0, …)
   → state FINALIZED
   Provider's EventContractNegotiationSubscriber, on FINALIZED:
        resolveBpn(consumerDid) via BDRS  → AgreementsBpnsStore
   (cold-BDRS-cache: first attempt can lose a race → "No BPN entry for agreement"; retry warms it)
```

### Flow D — Transfer & data pull
```
Consumer CP ── DSP transfer ──► Provider CP
   Provider issues an EDR (endpoint URL + short-lived token) → cached at the consumer
Consumer CP → GET /edrs/{id}/dataaddress → { endpoint: <provider DP>/api/public, authorization }
Consumer DP ── GET /api/public (Bearer EDR token) ──► Provider DP ──► Submodel backend / DTR
   → asset bytes returned to the consumer
```

### Flow E — Digital-twin discovery (provider data model)
```
Consumer → (through the negotiated EDR proxy) → Provider DTR
   GET /api/v3/shell-descriptors?limit=80&sortDirection=DESC[&cursor=…]
   → shell descriptors → submodelDescriptors[].endpoints[].href  (a dataplane public path)
   → follow the href (Flow D) → submodel JSON from the submodel backend
```

---

## 5. Trust model

- **Trusted issuer** = the operator's DID (`did:web:<issuerHost>:BPNL00000003CRHK`). Every
  connector is configured with it under `dcp.trustedIssuers` (IH) / `iatp.trustedIssuers`
  (stub). A VP is only accepted if signed by a trusted issuer.
- **Credential types** (all four issued to each participant):
  - `MembershipCredential` — dataspace membership (presence check).
  - `BpnCredential` — carries the BPN (a `bpn` subject claim; used by BPN policies).
  - `DataExchangeGovernanceCredential` — carries `contractVersion` (must exactly match
    `wallet.frameworkContractVersion`, default `1.0`).
  - `FrameworkAgreementCredential` — the signed framework agreement.
- **Two policy layers:** the **access policy** (catalog visibility — Flow B) vs the
  **usage/contract policy** (negotiation — Flow C). Value-checks (FrameworkAgreement version,
  BPN) belong in usage; presence (Membership) suffices for access.
- **Revocation:** the IssuerService maintains a **status list**; credentials carry an absolute
  status-list URL (a non-absolute URL breaks the BDRS/verifier revocation fetch → 400).

---

## 6. Wallet-mode comparison (stub vs IdentityHub)

| Aspect | `ssi-dim-wallet-stub` | IdentityHub |
|---|---|---|
| Nature | One centralized **mock** for all BPNs | Real DCP wallet; **per-participant** (or one shared multi-tenant) |
| STS | `POST /api/sts` (fabricated) | `POST /api/sts` (real SI token, keys in Vault) |
| Credential Service | one service, fabricates VPs | `…/api/credentials/v1/participants/<b64ctx>`, holds real VCs |
| Issuer | fabricated | **IssuerService** issues real VCs (Flow A) |
| Connector config keys | `iatp:` / `sts.dim.url` / `TX_IAM_IATP_CREDENTIALSERVICE_URL` | `dcp:` / `sts.div` / `TX_EDC_IAM_DCP_CREDENTIALSERVICE_URL` (legacy `TX_IAM_IATP_…` kept) |
| `participant.id` | the DID | DID; plus `participant.contextId` = the plain ParticipantContext id |
| Topology | single service | **shared** (one IH, all ParticipantContexts) or **per-participant** (one IH per BPN, own ingress host) |
| Source of truth | `_wallet-derive.tpl` + `wallet.mode` | same helpers; `_wallet-validate.tpl` enforces exactly one wallet is enabled |

Switch with `wallet.mode: stub | identityHub` (+ `identityHub.topology: shared | perParticipant`).
`templates/configmap-wallet-mode.yaml` renders on every install to force the validator to run.

---

## 7. Dataspace management / lifecycle

### 7.1 Provision (deploy)
`helm install umbrella charts/umbrella -f <profile>` — the profile picks the wallet mode +
topology (`charts/values-test-data-exchange*.yaml`). IH profiles must also layer the in-flight
image overlay (`…-local-0.17.0.yaml`).

### 7.2 Seed (post-install hooks, in weight order)
| Weight | Hook | Seeds |
|---|---|---|
| pre `-25` / post | `post-install-coredns-tx-test-patch` | CoreDNS `hosts{}` so pods resolve `*.tx.test` |
| `-5` | `post-install-vault-setup` | KV engine + initial secrets in each connector Vault |
| `-5` | `post-install-bdrs-setup` | BPN→DID directory (`bpnList`) → BDRS (matrix row 13) |
| `-3` | `post-install-identityhub-seed` | (IH only) ParticipantContexts + `edc-wallet-secret` → Vault + issue the 4 VCs (Flow A) |
| `-2` | `post-install-job-upload-testdata` | Provider assets + policies + contract defs + DTR shells + submodels |

### 7.3 Operate
- **Contracting** is driven through the connector **Management API** (`…/management/v3`):
  `assets`, `policydefinitions`, `contractdefinitions`, `catalog/request`, `edrs`,
  `contractnegotiations`, `transferprocesses` (X-Api-Key auth). The
  `hack/dcp-data-transfer-smoke.sh` script exercises exactly this surface end-to-end.
- **Credential lifecycle** (IH) is driven through the IssuerService Issuer-Admin API
  (add-holder, credential-offer, revoke/suspend/resume).
- **Config source of truth:** `_wallet-derive.tpl` (derived DIDs/URLs), `wallet.participants`
  (BPNs/roles/credentials), `configmap-wallet-mode.yaml` (surfaces values to the seed Jobs).
- **Secrets:** one Vault per connector; `edc-wallet-secret` = the STS client secret; plus
  EDC token-signing keys. A Vault wiped/dev-restart → DCP breaks until re-seeded.

---

## 8. Failure modes & diagnostics (field notes)

| Symptom | Cause | Fix |
|---|---|---|
| Connector crash-loops at boot: `No setting found for key tx.edc.iam.iatp.bdrs.server.url` | Connector image built from the wrong source (config-key mismatch with the chart) | Build from `tractusx-edc` **`main`**, not the BE-204 fork |
| Connector crash: `Failed to fetch client secret … edc-wallet-secret` / STS `401 invalid_client` | Vault not seeded / dev-Vault restarted | Re-run vault-setup + identityhub-seed; use prod-mode Vault for durability |
| Catalog returns **200 but empty** | A required VC missing, or **thin claims** (no `bpn` / no `contractVersion`) → value-check fails | Enrich the seed's credential subject (BpnCredential→`bpn`, DEG→`contractVersion`) |
| Transfer TERMINATES: **"No BPN entry found for agreement"** | BDRS directory empty, or cold-BDRS-cache race on the first negotiation | Ensure bdrs-setup ran; the smoke test auto-retries once to warm the cache |
| Data pull `500 {"errors":[]}` | Submodel backend has no data behind a DTR path (restarted / not seeded) | Re-run testdata; use the JPA+Postgres submodel backend for durability |
| Seed FATAL: `could not extract super-user API key` | Postgres-backed IssuerService restarted → key printed only on first boot | Reset the IssuerService super-user context so it re-emits the key |

---

## 9. Related docs

- **[ECOSYSTEM-GUIDE.md](../../../ECOSYSTEM-GUIDE.md)** — structural overview (all components, Helm layering).
- **[data-exchange-identity-hub.md](../../user/common/guides/data-exchange-identity-hub.md)** — deploy + seed + smoke test for the IH stack.
- **[how-tractus-x-umbrella-helm-charts-work.md](../../dev/how-tractus-x-umbrella-helm-charts-work.md)** — chart wiring / config flow.
- **`hack/dcp-data-transfer-smoke.sh`** — the runnable reference for Flows B–D (authoritative for endpoints).
- Bruno / Postman collections under `docs/common/api/`.

## NOTICE
This work is licensed under the [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/legalcode).
