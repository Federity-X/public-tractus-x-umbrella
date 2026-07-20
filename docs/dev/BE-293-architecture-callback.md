<!--
SPDX-License-Identifier: CC-BY-4.0
-->

# BE-293 — Architecture decision: credential-issuance completion signal

> Architecture decision record (ADR) for the BE-293 IdentityHub onboarding-wallet integration.
>
> ✅ **IMPLEMENTED & verified 2026-07-18** (holder-side push observer). The problem/decision/rationale
> below stand. One caveat: the **"Deployment config spec" table** further down predates the **F6**
> IssuerService holder-registration step, so it omits 4 keys —
> `APPLICATIONCHECKLIST__IDENTITYHUB__{ISSUERADMINBASEADDRESS,ISSUERADMINAPIKEY,ISSUERPARTICIPANTID,FRAMEWORKCONTRACTVERSION}`.
> For the complete **as-built** config (chart patch across 5 files, top-level `backend.walletProvider`,
> the value-gated `charts/umbrella/templates/didweb-resolver.yaml`, patch-and-repackage-with-fail-fast
> bootstrap) see `BE-293-cross-repo-changes-and-decisions.md` (findings F1–F6) and `BE-293-full-rebuild-runbook.md`.

## The problem

The Portal's `ApplicationChecklist` issues onboarding credentials (BPNL, MEMBERSHIP) with a
**uniform, closed abstraction**:

```
REQUEST_<X>_CREDENTIAL  ──►  AWAIT_<X>_CREDENTIAL_RESPONSE  ──►  (completed by an inbound PUSH callback)
```

Both existing issuers conform to it: `ssi-credential-issuer` and DIM each POST a callback to
the Portal when the credential is ready; the `AWAIT_*` step is *not* self-executing — it waits
for that push. This is deliberate: the orchestrator does not know or care *how* an issuer
produces a credential.

The Tractus-X **IssuerService (EDC 0.17.0)** does not fit that contract. Verified from the
`org.eclipse.edc:*:0.17.0` jars:

| Fact | Evidence |
|---|---|
| Issuance is a state machine `SUBMITTED → APPROVED → DELIVERED \| ERRORED` | `IssuanceProcessStates` |
| `transitionToDelivered()` only sets state — **no event emitted** | `IssuanceProcess` bytecode |
| **No `Listener` / `Observable` / `EventRouter`** in the issuance SPI | `issuerservice-issuance-spi` class inventory |
| Issuance is **holder-pull via DCP** (`dcp-issuer-api`); claims come from the issuer's `AttestationPipeline`, **not** the requester | jar inventory |
| Both sides expose a **queryable `StateEntityStore`** | `IssuanceProcessStore.query`, `HolderCredentialRequestStore.query` |
| Holder side tracks the request: `CREATED → REQUESTING → REQUESTED → ISSUED \| ERROR` with `participantContextId`, `issuerDid`, `getIdsAndFormats()` | `HolderCredentialRequest`, `HolderRequestState` |

So: the Portal wants a **push**; the IssuerService offers only **queryable state**, and there is
**no place to inject a Portal correlation id** into the DCP request.

## The decision

**An adapter in the issuer/identity domain (a `tractusx-identityhub` EDC extension) observes the
holder-side `HolderCredentialRequest` reaching `ISSUED`/`ERROR` via the stable public
`HolderCredentialRequestStore` SPI, and POSTs the Portal's credential-response callback — keyed
on `participantContextId` (= BPN) + requested credential type.** The Portal is unchanged: it keeps
its `REQUEST → AWAIT → push callback` abstraction, and IdentityHub *joins* it exactly like DIM/ssi.

### Why the holder side, not the issuer side

- The **holder request is initiated by the Portal's own `REQUEST_*` step**, so the Portal already
  owns the correlation (`participantContextId` = the BPN it manages, and the credential type it
  asked for). No DCP-request injection needed — which is fortunate, because we proved it's
  impossible (claims come from attestations).
- `ISSUED` is the state the Portal actually cares about — *"the holder wallet now holds the
  credential"* — which is the real onboarding success condition. Issuer-side `DELIVERED` only
  means "issuer sent it."
- For onboarding at scale the natural topology is a **shared multi-tenant IdentityHub** hosting
  all holder ParticipantContexts, so the adapter deploys **once** and observes every holder.

### Why not the two rejected alternatives

- **Poll-steps inside portal-backend** (my first suggestion — correctly rejected): puts
  issuer-transport knowledge *into* the orchestrator and forks a closed, uniform abstraction
  (push-callback issuance) into a second shape. Wrong domain, wrong coupling.
- **Fork eclipse-edc core to add issuance eventing**: architecturally purest (root-cause push),
  but forks EDC *core* → version divergence and painful upgrades — the exact anti-pattern this
  project already got burned by (the BE-204 fork crash-loops). The eventing belongs upstream as a
  **PR to eclipse-edc**, not a locally maintained core fork. Our deliverable rides the stable SPI;
  when upstream adds a holder-request `Observable`, the adapter swaps `store.query(ISSUED)` for an
  `EventSubscriber` — a one-file change.

The adapter uses **only stable public SPIs** (`HolderCredentialRequestStore.query`,
`HolderRequestState.ISSUED`) in an extension in a runtime **we already build from source**
(PR #309) — no EDC core divergence. The in-process poll is an implementation detail *inside the
issuer-domain adapter*, invisible to the Portal — categorically different from portal-side
poll-steps.

## End-to-end flow

```
1. CREATE_IDENTITY_HUB_WALLET   (portal-backend, DONE)
      └─► create holder ParticipantContext in the (shared) IdentityHub   [IdentityHubService]

2. REQUEST_BPN_CREDENTIAL       (portal-backend, IdentityHub issuer strategy)
      └─► POST holder IdentityHub credential-request API {issuerDid, type=BPNL}
      └─► schedule AWAIT_BPN_CREDENTIAL_RESPONSE   (existing step, unchanged)

3. DCP dance  (holder IdentityHub ⇄ IssuerService)  → HolderCredentialRequest = ISSUED
      └─► credential stored in the holder wallet

4. ADAPTER EXTENSION  (tractusx-identityhub, holder IdentityHub runtime)
      └─► observes ISSUED via HolderCredentialRequestStore
      └─► POST the EXISTING BPN-keyed Portal endpoint {bpn, status, message}
             /api/administration/registration/issuer/{bpncredential|membershipcredential}
      └─► Portal completes AWAIT_BPN_CREDENTIAL_RESPONSE  (StoreBpnlCredentialResponse path)

   (MEMBERSHIP credential: identical shape)
```

## Key finding: the callback receiver already exists and is issuer-agnostic

The Portal endpoints `issuer/bpncredential` + `issuer/membershipcredential` already accept
`IssuerResponseData { bpn, status, message }`, resolve the application via
`GetSubmittedApplicationIdsByBpn(bpn)`, and drive the shared `Store*CredentialResponse` advance
(auth roles `update_application_{bpn|membership}_credential`). They are **BPN-keyed, not
correlation-id-keyed** — exactly what a poll-derived signal can produce. So the adapter reuses
them verbatim: **no new controller, no new resolver, no state-machine change.** Strong evidence
the design matches the Portal's original intent — any issuer can drive the callback by BPN.

## Implementation increments

1. **portal-backend (REQUEST side only)** — make `IIssuerComponentService` pluggable by
   `WalletProviderId`: keep the DIM impl byte-identical; add `IdentityHubIssuerComponentService`
   whose `CreateBpnlCredential`/`CreateMembershipCredential` trigger the **holder credential-request
   API** instead of the DIM HTTP call. The shared `IssuerComponentBusinessLogic` (schedules
   `AWAIT_*`) and the callback receiver are **unchanged**.
2. **tractusx-identityhub** — Java EDC extension: `@Inject HolderCredentialRequestStore`, periodic
   scan for `ISSUED`/`ERROR` not yet notified, POST the existing BPN-keyed Portal endpoint, mark
   notified (idempotent). Config: Portal base URL + service-account auth.
3. EF migration (new `ProcessStepTypeId`s), appsettings + umbrella config, tests, image forks,
   unified-profile deploy, end-to-end validation.

## Deployment config spec (turnkey — exact keys from the implemented code)

**Portal backend** (`processes-worker` + `administration-service`), under the `ApplicationChecklist`
section — set as env (`APPLICATIONCHECKLIST__<Section>__<Key>`). Presence of the `IdentityHub`
section is what enables its validation, so set it only on IdentityHub deployments:

| Key | Value |
|---|---|
| `ApplicationChecklist:IssuerComponent:WalletProvider` | `IdentityHub` |
| `ApplicationChecklist:IdentityHub:BaseAddress` | `http://<shared-ih>/api/identity` |
| `ApplicationChecklist:IdentityHub:ApiKey` | IdentityHub super-user key |
| `ApplicationChecklist:IdentityHub:DidDocumentBaseLocation` | did:web host base (e.g. `ih.tx.test`) |
| `ApplicationChecklist:IdentityHub:CredentialServiceBaseAddress` | `http://<shared-ih>/api/credentials` |
| `ApplicationChecklist:IdentityHub:IssuerDid` | `did:web:<issuer-host>:<issuer>` |
| `ApplicationChecklist:IdentityHub:BpnCredentialDefinitionId` | issuer cred-def id for BpnCredential |
| `ApplicationChecklist:IdentityHub:MembershipCredentialDefinitionId` | issuer cred-def id for MembershipCredential |

(`BpnCredentialType`/`MembershipCredentialType`/`CredentialFormat`/`HolderRole` default correctly.)
Leaving the `IdentityHub` section unset keeps stub/DIM deployments unchanged (validation skipped).

**IdentityHub runtime** (the `portal-credential-callback` extension) — EDC settings, set as env
with the EDC normalisation (`tx.portal.callback.base-url` → `TX_PORTAL_CALLBACK_BASE_URL`).
Unset `base-url` leaves the extension inert:

| Setting | Value |
|---|---|
| `tx.portal.callback.base-url` | `https://portal-backend.<host>` |
| `tx.portal.callback.token-url` | `https://centralidp.<host>/auth/realms/CX-Central/protocol/openid-connect/token` |
| `tx.portal.callback.client-id` | technical user with `update_application_bpn_credential` + `update_application_membership_credential` |
| `tx.portal.callback.client-secret` | that user's secret |

(`bpn-credential-type`/`membership-credential-type`/`scope`/`interval-seconds` default correctly.)

## Status — implemented & verified

Implemented across three repos and **validated end-to-end** (fresh from-scratch umbrella build): a
clean Portal onboarding runs the whole chain automatically — `CREATE_IDENTITY_HUB_WALLET →
VALIDATE_DID_DOCUMENT → TRANSMIT_BPN_DID → REQUEST_{BPN,MEMBERSHIP}_CREDENTIAL → (holder pull) →
observer callback → AWAIT_*_CREDENTIAL_RESPONSE → … → CLEARING_HOUSE → activation` — both credentials
ISSUED, both callbacks SUCCESSFUL, no bridges.

For the **as-built** details (the exact chart patch, config keys incl. the F6 IssuerService
holder-registration keys, and the deploy/verify steps) see:

- `BE-293-cross-repo-changes-and-decisions.md` — the change + decision record (D1–D11) and the
  fresh-rebuild findings F1–F6.
- `BE-293-full-rebuild-runbook.md` — the from-scratch build → deploy → verify runbook.
- `../user/common/guides/data-exchange-identity-hub.md` — the user-facing IdentityHub guide.
