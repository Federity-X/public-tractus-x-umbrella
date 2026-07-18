<!--
  Copyright (c) 2026 Contributors to the Eclipse Foundation
  SPDX-License-Identifier: CC-BY-4.0
  INTERNAL task breakdown — do NOT commit to main (per repo working rules). Local reference only.
-->

# BE-293 — POC: IdentityHub + IssuerService as the Portal onboarding wallet

> **Jira:** <https://dsaas-tvs.atlassian.net/browse/BE-293>
> **Goal:** make the Tractus-X Portal onboarding flow issue onboarding credentials via the
> **IdentityHub IssuerService** (DCP holder-pull), with **IdentityHub the DEFAULT wallet and
> SSI-DIM a selectable OPTION** (not a replacement). Deliver a **single locally-deployed umbrella
> release** that runs onboarding *and* the DCP data-exchange the panel uses.
> **Draft only** — sub-tasks to be created under BE-293 in Jira. Local planning doc; do not commit.

## PRODUCTION ARCHITECTURE — DECIDED (supersedes the POC-vs-fork framing below)

After deep-diving portal-backend, tractusx-identityhub/issuerservice, and eclipse-edc, the
production-best approach is a **HYBRID, phased** design (NOT a throwaway adapter shim):

1. **Native IdentityHub wallet+issuer strategy inside `portal-backend`** — the durable,
   upstreamable core. Model it on how **DIM was layered onto Custodian**: a new
   `src/externalsystems/IdentityHub.Library` (`CreateIdentityHubWalletAsync` → new
   `CREATE_IDENTITY_HUB_WALLET` step → reuse the existing
   `VALIDATE_DID_DOCUMENT → TRANSMIT_BPN_DID → REQUEST_BPN_CREDENTIAL` chain), a second
   `IIssuerComponentService` impl (`IdentityHubIssuerComponentService`, x-api-key auth to the
   IssuerService `/api/admin/v1alpha`), and promote the existing `bool UseDimWallet` →
   **`enum WalletProvider {Custodian, Dim, IdentityHub}`**. Keep the Portal's existing
   `request → AWAIT_*_RESPONSE → callbackUrl` seam and the inbound
   `/api/administration/registration/issuer/*credential` handlers **UNCHANGED**.
2. **Poll→push callback bridge as a `tractusx-identityhub` EDC extension** (NOT a standalone
   microservice) — the one place that resolves the impedance mismatch (IssuerService is
   DCP holder-pull with **no callback**; the Portal expects a push). Interim: a scheduled
   poller over the IssuanceProcess API that POSTs the Portal-shaped `IssuerResponseData` when
   a credential reaches `DELIVERED`/`ERRORED`. It reads existing SPI only → **zero upstream-EDC
   fork needed to ship**.
3. **Upstream the missing `IssuanceProcess` eventing to `eclipse-edc`** (parallel, off the
   critical path) — add `IssuanceProcessObservable/Listener` + typed events + `EventRouter`
   publisher, mirroring the blessed ParticipantContext/KeyPair/CredentialOffer pattern. Once
   merged, the bridge swaps its poller for an `EventSubscriber` — a localized change that never
   touches portal-backend.

**"IdentityHub default + SSI-DIM option" is purely additive:** SSI-DIM stays first-class as
`WalletProvider.Dim` (byte-identical; SAP-hosted-external in real deployments anyway), and the
default flips via umbrella `wallet.mode=identityHub` + the Portal `WalletProvider` enum.

### Repos to develop in (answering "which repo do I clone")
| Repo | Role | Have it locally? | Effort |
|---|---|---|---|
| **`portal-backend`** (Federity-X fork of eclipse-tractusx/portal-backend) | native wallet+issuer strategy (the core) | ✅ `/Users/tvs-indetechs/projects/portal-backend` | XL |
| **`tractusx-identityhub`** | the poll→push callback-bridge EDC extension (in `extensions/`) | ✅ `/Users/tvs-indetechs/IdeaProjects/public-tractusx-identityhub` | L |
| **`eclipse-edc`** | upstream IssuanceProcess eventing (parallel; NOT needed for the interim poller) | ❌ **would need cloning** — only for the upstream track | L |
| **`tractus-x-umbrella`** | config: `wallet.mode=identityHub` default, IssuerService key via Secret | ✅ this repo | S |

**So for the interim/POC deliverable you already have every repo needed** (portal-backend,
tractusx-identityhub, umbrella). **`eclipse-edc`** is the only new clone, and only for the
parallel upstream-eventing contribution — not required to ship BE-293 with the poller.

### Open decisions (need your call — see bottom of file)
Managed IdentityHub wallet vs BYOW-style; global `WalletProvider` enum vs per-participant
DID-capability routing; ship the interim poller now vs wait for upstream EDC eventing;
issuer-side `DELIVERED` vs holder-side `ISSUED` as the authoritative signal; who owns the
CredentialDefinition/attestation seed.

---

## Where we already are (foundation — do NOT redo)

- **IdentityHub + IssuerService bundle works in the umbrella**; full DCP data transfer validated on
  the per-participant-postgres profile. The umbrella `post-install-identityhub-seed.yaml` Job
  **already drives the IssuerService admin API end-to-end** (issuer ParticipantContext →
  attestations → credentialDefinitions → holders → credential request → retrieve). **This is the
  reference** for how the Portal must drive the IssuerService.
- **Portal onboarding works on the STUB wallet** (Phase B, release `portal-b`): Portal + CentralIDP +
  SharedIDP + BPDM + ssi-credential-issuer + discovery; company registration completes (with a
  Clearinghouse SQL skip). This is the **"before" state** BE-293 migrates from.
- Both halves run **separately** today. BE-293 = **unify** them.

## Key facts the mapping surfaced (portal-backend `fx-connector-ui` fork)

- **BYOW seam already present** (upstream Portal PR #1422): `BringYourOwnWalletController` +
  `BringYourOwnWalletBusinessLogic`, `did:web` validated by `UniversalDidResolverService`. The
  **only** existing branch that switches issuance mode is the boolean
  `CompanyRepository.IsBringYourOwnWallet` (row with `ClientId == "BYOWCLIENT_ID"`).
- **Issuer call site:** `IssuerComponent.Library/BusinessLogic/IssuerComponentBusinessLogic.cs`
  (`CreateBpnlCredential`/`CreateMembershipCredential`) → sets
  `TechnicalUserDetails = isBringYourOwnWallet ? null : …` — **the holder-pull null branch already
  exists**. HTTP client `IssuerComponentService.cs` → ssi-credential-issuer.
- **The poll→callback bridge target:** `AWAIT_BPN_CREDENTIAL_RESPONSE (26)` /
  `AWAIT_MEMBERSHIP_CREDENTIAL_RESPONSE (28)` are **non-executable await steps** in
  `ApplicationChecklistHandlerService._stepExecutions`, completed **only** by ssi-credential-issuer's
  inbound callback (`POST /api/administration/registration/issuer/{bpn,membership}credential` →
  `Store*CredentialResponse`). IdentityHub has **no callback** → these must become poll-driven.
- **No issuer-selection factory exists** — it must be built.
- **Deployment:** umbrella pulls the **released** portal chart `2.6.0` (no BE-293 code) → a **fork
  image build** is required for 3 services (administration-service, processes-worker,
  registration-service). The IS/IH super-user API key is **printed once to the pod log** and scraped
  by the seed Job — a long-lived Portal pod **cannot** scrape logs, so a stable key delivery is needed.

---

## Sub-tasks

### BE-293-1 · Spike: pin the IssuerService issuance-status API + prototype the poll→callback bridge
- **Priority:** P0 (blocker / de-risk first) · **Effort:** M · **Depends on:** —
- **Why:** the core unknown. The onboarding state machine only leaves `AWAIT_*` via ssi-credential-issuer's async **push** callback; IssuerService is DCP-CIP **holder-pull with no callback**, and the `IssuanceProcess`/`CredentialRequestStatus` response shapes + `holderPid` correlation are untyped (`object`) in the OpenAPI.
- **Work:** no production code — a throwaway script/harness against the live per-participant-postgres IH/IS release. Exercise IS `POST .../issuanceprocesses/query` + `GET .../issuanceprocesses/{id}`, IH `GET .../credentials` (state `500`/ISSUED), `GET .../credentials/request/{holderPid}`. Record the `state` enum (APPROVED/DELIVERED/ERRORED + `errorDetail`), the `500=ISSUED` code, where `type` nests, and how `holderPid` correlates a request back to a checklist item. Reference driver: `post-install-identityhub-seed.yaml`.
- **Done when:** a written **status contract** (exact fields the poller keys on) + a **working poll-only prototype** that deterministically detects ISSUED and ERRORED, + documented `holderPid` uniqueness strategy.

### BE-293-2 · Deliver a durable IssuerService super-user API key to the Portal pod
- **Priority:** P0 · **Effort:** M · **Depends on:** —
- **Why:** biggest deployment gap. The key is log-printed once and scraped at runtime; a Portal pod can't scrape logs and a restart breaks a scraper.
- **Work:** set a stable key at boot (`edc.ih.api.superuser.key` / `apiKeyAlias` → Vault) for both `identity-hub` and `issuer-service` (`identity-and-trust-bundle/values.yaml`); have the seed Job write the resolved key into a **k8s Secret** the Portal mounts (the `wallet-mode` ConfigMap deliberately omits it — must come via Secret). Alternatively a dedicated Portal admin ParticipantContext with a stable scoped key.
- **Done when:** the key is stable across pod restarts (no log-scraping); a Secret carries it in the Portal namespace; fresh install and full-restart both yield the same usable key.

### BE-293-3 · Add the issuer-selection strategy/router seam in portal-backend
- **Priority:** P1 · **Effort:** M · **Depends on:** BE-293-1
- **Work:** introduce an `IIssuerComponentService` factory/strategy in `IssuerComponent.Library`, registered via `AddIssuerComponentService`, keyed by a new flag (`wallet.issuerMode: identityHub|dim`) and/or DID capability (holder has `did:web` → holder-pull). Reuse the existing `TechnicalUserDetails==null` branch for IdentityHub; keep the DIM push branch byte-identical. Switch **both** config sections consistently (`IssuerComponent` for the checklist worker; `Issuer` for the admin framework path).
- **Done when:** `issuerMode=dim` is regression-identical to today; `issuerMode=identityHub` (or a `did:web` holder) resolves the IdentityHub impl; unit test covers both routes.

### BE-293-4 · Implement `IdentityHubIssuerComponentService` (DCP-CIP admin/identity client)
- **Priority:** P1 · **Effort:** L · **Depends on:** BE-293-1, BE-293-2, BE-293-3
- **Work:** new library `src/externalsystems/IdentityHubIssuer.Library` driving the admin API the way the seed does — ensure/register holder ParticipantContext + `did:web`; IS `POST .../holders`; IH `POST .../credentials/request` (unique `holderPid` per company+type); map onboarding types → `credentialDefinition` ids; idempotent create-on-409 (capture `clientSecret` only on 201); **x-api-key** header auth from BE-293-2; handle 0.17.0 plain-participantContextId paths.
- **Done when:** the service registers a holder and triggers a DCP issuance that reaches ISSUED; 409 handled idempotently; distinct companies/types → distinct `holderPid` (no PK collision); no log-scrape / no Keycloak token for IS calls.

### BE-293-5 · Build the poll→callback bridge in the ApplicationChecklist state machine
- **Priority:** P0 (core-risk implementation) · **Effort:** L · **Depends on:** BE-293-1, BE-293-4
- **Work:** in `ApplicationChecklistHandlerService.cs` add **POLL_*** step types (or make `AWAIT_*` executable in identityHub mode) that poll IS/IH status; on terminal **ISSUED** synthesize `IssuerResponseData{bpn,status,message}` and invoke the **existing** `Store{Bpnl,Membership}CredentialResponse` to advance `BPN → REQUEST_MEMBERSHIP → START_CLEARING_HOUSE`; on **ERRORED** map `errorDetail` to the failure path. Gate `callbackUrl`+`AWAIT` scheduling on issuer mode (IdentityHub → omit callback, schedule POLL). Add `ProcessStepTypeId` enum entries; bounded poll cadence/timeout. Trace the FrameworkAgreement/DataExchangeGovernance path (synchronous today).
- **Done when:** identityHub-mode checklist advances past `AWAIT_*`/`POLL_*` purely by polling to `START_CLEARING_HOUSE`; dim mode unchanged; ERRORED surfaces as a checklist failure (not a silent stall); poll timeout can't deadlock the worker.

### BE-293-6 · Wire config binding + BYOW holder-DID onboarding for the IdentityHub route
- **Priority:** P1 · **Effort:** M · **Depends on:** BE-293-3, BE-293-4
- **Work:** new appsettings section for the IdentityHub IssuerService endpoint + api-key (bound in `ApplicationChecklistExtensions.cs` and `Administration.Service/Program.cs`); enable the BYOW branch so `did:web` holders skip `CREATE_*_WALLET`; audit the ~18 `UseDimWallet` references for DIM-only assumptions; confirm the `START_CLEARING_HOUSE` handoff still fires (keep the Phase B Clearinghouse SQL skip).
- **Done when:** admin + worker bind the IdentityHub config; a `did:web` company skips `CREATE_*_WALLET`; no `UseDimWallet` path forces DIM when `issuerMode=identityHub`; `MEMBERSHIP → START_CLEARING_HOUSE` still fires after the poll steps.

### BE-293-7 · Build & push fork portal-backend images to kind-registry
- **Priority:** P1 · **Effort:** M · **Depends on:** BE-293-4, BE-293-5, BE-293-6
- **Work:** build from `docker/Dockerfile-{administration-service,processes-worker,registration-service}` (.NET 9, VersionPrefix 2.6.0), push to `kind-registry:5000` (be241 pattern). Only these 3 services need fork tags; the rest stay on released `2.6.0`.
- **Done when:** the 3 fork images build and are present in kind-registry; run in-cluster with `pullPolicy: IfNotPresent`; tags recorded for BE-293-8.

### BE-293-8 · Create the unified umbrella profile (identityHub default, validator satisfied)
- **Priority:** P1 · **Effort:** M · **Depends on:** BE-293-7, BE-293-2
- **Work:** new `charts/umbrella/values-adopter-portal-onboarding-identityhub.yaml` layering the onboarding set on top of `identity-and-trust-bundle` (identity-hub[-postgres] + issuer-service). Set `wallet.mode: identityHub` as **default** (keep stub selectable), keep `_wallet-validate.tpl` intact; satisfy the render guards (`imagesOverridden` sentinel / layer `-local-0.17.0`; `ssi-dim-wallet-stub.enabled: false`). Keep `ssi-credential-issuer` enabled as the SSI-DIM option (dual-issuer). Override the 3 portal images to the BE-293-7 fork tags.
- **Done when:** `helm template` renders without tripping the validators; one release brings up onboarding **and** the IH+IS DCP stack; switching `wallet.mode: stub` still renders and selects the stub.

### BE-293-9 · Inject IssuerService URL, issuer DID, and api-key into the Portal backend
- **Priority:** P1 · **Effort:** M · **Depends on:** BE-293-2, BE-293-8
- **Work:** point `portal.backend.administration.issuerdid` at `did:web:issuer-service.tx.test:<operatorBpn>` (from `_wallet-derive.tpl`); add the IssuerService admin BaseAddress value; mount the BE-293-2 Secret into admin + worker; make the stub-wallet wiring (`custodianAddress`, `dimWrapper.*`, `dim.*`) conditional on the selected mode; set the `issuerMode` flag.
- **Done when:** admin + worker start with IssuerService BaseAddress + issuer DID + api-key populated; no active hard-coded stub addresses when `mode=identityHub`; the `issuerMode` flag reaches both worker and admin.

### BE-293-10 · Fix the `memberOf` / issuer-bootstrap ownership gaps
- **Priority:** P2 · **Effort:** M · **Depends on:** BE-293-1, BE-293-8
- **Work:** keep the seed Job as the **one-time** issuer bootstrap (issuer ParticipantContext + attestations + one credentialDefinition per type); the Portal drives only per-company holder register+request+poll. Address `MembershipCredential.credentialSubject.memberOf` (holders table has no `member_of` column → DB migration / holder-model mapping). Confirm the 0.17.0 `additionalContext` limitation (issued VCs carry only base W3C `@context`) is non-blocking for the onboarding credential set, or log it as a follow-up.
- **Done when:** issuer bootstrap is idempotent (409-safe); MembershipCredential issued with a correct `memberOf` (or documented workaround); `additionalContext` confirmed non-blocking or logged.

### BE-293-11 · End-to-end verification of the unified release
- **Priority:** P1 · **Effort:** L · **Depends on:** BE-293-5, BE-293-6, BE-293-9, BE-293-10
- **Work:** deploy the unified profile with fork images; run a company registration to completion; verify BPN + Membership (+ Framework/DEG) credentials issued **via IdentityHub IssuerService** and landed in the holder's IH (`state==500`); confirm the **poll steps** advanced the state machine with no callback; run the panel DCP flow on the same release; switch `wallet.mode: stub` and confirm onboarding still completes via ssi-credential-issuer; sanity-check full-restart durability (Raft vaults + postgres) doesn't break issuance or key delivery.
- **Done when:** a company onboards end-to-end with credentials via IssuerService; DCP catalog→transfer→fetch succeeds on the same release; stub mode still onboards via ssi-credential-issuer (SSI-DIM not replaced); a restart leaves issuance working.

---

## Execution order & priorities

**Recommended order (dependency-first):**
`BE-293-1 → BE-293-2 → BE-293-3 → BE-293-4 → BE-293-5 → BE-293-6 → BE-293-7 → BE-293-8 → BE-293-9 → BE-293-10 → BE-293-11`

**De-risk FIRST (riskiest unknown):** the **poll→callback bridge** (BE-293-1). IssuerService/IdentityHub
is holder-pull with no push callback, but the Portal state machine only leaves `AWAIT_*` via
ssi-credential-issuer's inbound callback, and the status response shapes + `holderPid` correlation are
untyped. Pin the terminal-state contract (`500`=ISSUED / ERRORED+`errorDetail`) and a working poll-only
detector against the live IS/IH release **before** writing the adapter (BE-293-4) or touching the state
machine (BE-293-5).

| Priority | Sub-tasks | Meaning |
|---|---|---|
| **P0** | BE-293-1, BE-293-2, BE-293-5 | Blockers / core risk — nothing works without these |
| **P1** | BE-293-3, BE-293-4, BE-293-6, BE-293-7, BE-293-8, BE-293-9, BE-293-11 | Core delivery path |
| **P2** | BE-293-10 | Correctness follow-up (can trail the happy path) |

**Two parallelizable tracks after BE-293-1:**
- *Code track* (portal-backend fork): BE-293-3 → 4 → 5 → 6 → 7
- *Deploy track* (umbrella): BE-293-2 → 8 → 9, plus BE-293-10

They converge at **BE-293-11** (end-to-end verification).
