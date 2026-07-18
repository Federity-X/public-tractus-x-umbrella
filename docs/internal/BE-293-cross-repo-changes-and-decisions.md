<!--
  Copyright (c) 2026 Contributors to the Eclipse Foundation
  SPDX-License-Identifier: CC-BY-4.0
  INTERNAL decision record — do NOT commit to main (per repo working rules). Local reference only.
-->

# BE-293 / sig-release #1609 — cross-repo change & decision record

Why this file: the effort changes **three repos** (plus builds from two more). This is the single place
that says **what changed in each repo, WHY, and which alternatives were rejected**. It complements the other
internal docs — it does not repeat them:

- `BE-293-architecture-callback.md` — the deep ADR for *how the issuance-completion signal is delivered*.
- `BE-293-full-rebuild-runbook.md` — the *how-to* to build & deploy the whole thing from scratch.
- `BE-293-subtasks.md` — the task breakdown.
- `extensions/portal-credential-callback/UPSTREAM-ISSUE.md` (identityhub repo) — the upstream feature request.

## Goal (one sentence)

Let the Catena-X **Portal onboarding** use the **Tractus-X IdentityHub + IssuerService** as the holder wallet
(instead of the SAP/DIM wallet), so that approving a company creates its wallet on the IdentityHub, the
IssuerService issues its BPN/Membership credentials, and the Portal's onboarding checklist advances — all on
the OSS umbrella stack.

## Repos touched (and their role)

| Repo | Branch | Role | Our changes? |
|---|---|---|---|
| **public-tractusx-identityhub** | `feat/holder-credential-request-status-callback` (on Federity-X `fix/321-322-dcp-e2e-collections-and-charts`) | The wallet runtime + **our new observer extension** | **Yes** (new module + fixes) — uncommitted |
| **portal-backend** | `feat/BE-293-identityhub-wallet` (on eclipse-tractusx) | Portal backend routed to the IdentityHub wallet | **Yes** — uncommitted working tree; built into `:be293` images |
| **public-tractus-x-umbrella** | `feature/BE-241-admin-panel-per-participant-plus` | Wiring/compose (overlays, seed, worker config, docs) | **Yes** — uncommitted |
| public-tractusx-edc | `main` (== upstream) | Connectors (DCP) | No — build only |
| public-sldt-digital-twin-registry | `feat/shell-descriptors-sort-direction` | DTR | No — build only |

---

## Change inventory per repo

### 1. identityhub — `extensions/portal-credential-callback/` (NEW module) + runtime wiring
- New `ServiceExtension` that scans the `HolderCredentialRequestStore` for requests reaching a terminal state
  (ISSUED/ERROR) and POSTs the Portal's existing issuer callback (OAuth2 client-credentials). Inert unless
  `tx.portal.callback.base.url` is set.
- Wired into `runtimes/identityhub` + `runtimes/identityhub-memory` (`build.gradle.kts`, `settings.gradle.kts`,
  `gradle/libs.versions.toml`).
- Two fixes made this session (see D3, D4).
- `UPSTREAM-ISSUE.md`: proposes the missing SPI (a `HolderCredentialRequest` observable/EventRouter event).

### 2. portal-backend — `feat/BE-293-identityhub-wallet` (IdentityHub as wallet provider)
- `externalsystems/IssuerComponent.Library/*` — the IdentityHub issuer/identity admin client + DI + settings.
- `administration/.../RegistrationBusinessLogic.cs` + `RegistrationSettings.cs` — the onboarding checklist steps
  for the IdentityHub route (`CREATE_IDENTITY_HUB_WALLET`, `VALIDATE_DID_DOCUMENT`, and the
  `AWAIT_{BPN,MEMBERSHIP}_CREDENTIAL_RESPONSE` gates the callback advances).
- `PortalBackend.PortalEntities/Enums/ProcessStepTypeId.cs` + migrations — the new step-type ids (809/810 …).
- `Bpdm.Library/*` — BPN handling for the IdentityHub route.
- Uses upstream "bring your own wallet" (#1422) + DID-document validation (#1475) as the base. Built into
  `tractusx/portal-*:be293`.

### 3. umbrella — overlays, seed, worker config, docs
- `charts/values-test-data-exchange-identity-hub-postgres.yaml` — durable Postgres IH (existing repo file; the profile we select).
- `charts/values-connector-persistence.yaml` **(new)** — connector Postgres PVCs + control-plane probe widening.
- `charts/values-callback-activation.yaml` **(new)** — pin `EDC_IH_API_SUPERUSER_KEY` + callback env (`sa-cl24-01`).
- `charts/umbrella/values-combined-portal-additions.yaml` **(new)** — Portal + IdP + BPDM enablement; worker
  `IDENTITYHUB__BASEADDRESS`→admin host; mailer→`smtp4dev:25`; Portal `identityHub.apiKey`=pinned key.
- `charts/tx-data-provider/templates/post-install-identityhub-seed.yaml` — seed idempotency guard.
- `charts/umbrella/templates/configmap-portal-testdata-seeding.yaml` — test-data BPN fix (plain BPN, not the DID).
- `charts/umbrella/templates/didweb-resolver.yaml` **(new)** + `didwebResolver.enabled` value — in-cluster did:web
  Universal-Resolver shim (value-gated chart template); the worker's `dim.universalResolverAddress` (in the overlays)
  points at it so `VALIDATE_DID_DOCUMENT` resolves `did:web:*.tx.test` with no bridge (D11).
- `hack/helm-dependencies.bash` + `hack/patches/` — repackage + BE-293 portal chart patch.
- `docs/internal/BE-293-*.md` — this record + the runbook + the callback ADR + subtasks.

---

## Decisions — what / why / alternatives rejected

### D1 · Deliver the issuance-completion signal from the HOLDER side (IdentityHub observer), not the issuer
**Why:** the Portal's `ProcessIssuer{Bpn,Membership}Response` callback receiver already exists and is
issuer-agnostic; the holder runtime is the one place that knows a `HolderCredentialRequest` reached a terminal
state. **Alternatives rejected** (full detail in `BE-293-architecture-callback.md`): (a) fork the Portal to
*poll* the IssuerService issuance API — couples the Portal to issuer internals + adds a poller; (b) add issuer-side
push in the IssuerService — issuer-specific, doesn't generalise. Chosen: a small holder-side observer that reuses
the Portal's existing endpoint. Long-term: replace polling with a real SPI event (see `UPSTREAM-ISSUE.md`).

### D2 · Durable **Postgres**-backed IdentityHub (not in-memory)
**Why:** for a real onboarding demo the wallet store must survive a restart — a Portal-onboarded participant's
wallet + credentials cannot be "re-seeded" the way test participants can. Proven: killing the IH pod preserved
5 participant contexts + 16 credentials; DCP stayed green. **Alternatives rejected:** (a) in-memory IH + re-seed
on boot — fine for the data-exchange sandbox, but loses real onboarded wallets on any restart; (b) per-participant
IHs — heavier, and orthogonal to durability; (c) external/managed wallet — defeats the "OSS umbrella" goal.
Caveat: full Docker-restart durability also needs a persistent/Raft `umbrella-vault` (signing keys); the Postgres
IH already survives an IH **pod** restart.

### D3 · Extension settings use **dot-separated** keys (`tx.portal.callback.base.url`), not hyphens
**Why:** EDC maps env vars `TX_PORTAL_CALLBACK_BASE_URL` → `tx.portal.callback.base.url` (`_`→`.`); a hyphenated
key (`...base-url`) is **unreachable via any env var**, so the extension silently stayed disabled in k8s.
Dot-form is both EDC-idiomatic and env-settable. **Alternative rejected:** ship a config file into the IH pod to
carry hyphenated keys — more chart surgery, non-idiomatic, and still surprising.

### D4 · Callback HTTP client pinned to **HTTP/1.1**
**Why:** the JDK `HttpClient` defaults to HTTP/2, which over cleartext `http://` attempts an h2c upgrade that
ingress-nginx/Keycloak don't complete → the request hangs to the 30 s timeout. `curl` (HTTP/1.1) hit the same
endpoint in ~6 ms. **Alternative rejected:** front everything with TLS/ALPN so HTTP/2 negotiates cleanly —
disproportionate for a sandbox and unrelated to the feature.

### D5 · Callback client id = **`sa-cl24-01`** (not `sa-cl2-01`)
**Why:** `sa-cl24-01` is the ONLY base service account assigned BOTH `Cl2-CX-Portal` roles
`update_application_bpn_credential` + `update_application_membership_credential` (verified in the CX-Central
realm seed). `sa-cl2-01` (the earlier guess) lacks them → 401. **Alternative rejected:** add the roles to a
different SA — changes the realm seed unnecessarily when a correct SA already exists.

### D6 · Portal worker `IDENTITYHUB__BASEADDRESS` → the **admin** ingress host
**Why:** participant-management (create/activate) is served only on `identity-hub-admin.tx.test`; the public
`identity-hub.tx.test` 405s on `POST /participants`. The credential-service + DID location stay on the public
host on purpose (they're what others resolve). **Alternative rejected:** expose the admin API on the public host —
loosens the intended public/admin split.

### D7 · Portal mailer → **`smtp4dev:25`**
**Why:** the default `smtp.tx.test:587` is the HTTP ingress (no SMTP listener) → every MAILING process hangs ~75 s
on connect-timeout and starves the single-threaded processes-worker before it reaches the onboarding checklist.
`smtp4dev:25` is the in-cluster catcher → mail resolves fast. **Alternative rejected:** disable mailing — hides a
real misconfiguration and the worker still processes mail steps.

### D8 · **Seed idempotency guard** (skip re-requesting an already-ISSUED credential)
**Why:** the seed runs on every install/upgrade; without the guard, re-runs re-issue duplicate VCs (on the
in-memory store a duplicate holderPid does not collide), inflating the holder VP until it overflows the
bdrs-server 8 KB Jetty request-header limit → HTTP 431 → BDRS resolution fails. **Alternatives rejected:**
(a) raise the Jetty header size — EDC 0.17.0 exposes no such setting; (b) shrink/scope the VP — deeper EDC change.
The guard is minimal and also makes the Postgres profile's single seed job cleanly idempotent (4 creds/holder).

### D9 · **Connector Postgres persistence** (PVCs) + control-plane probe widening
**Why:** emptyDir connector DBs are wiped whenever a `helm upgrade` re-applies the StatefulSets → EDC schema
gone → `relation "edc_contract_negotiation" does not exist` → DCP breaks. PVCs survive the upgrade. **Alternative
considered/kept as fallback:** just restart the EDC planes after each upgrade to re-provision the schema — works
but is a manual step and loses any real data; persistence is the durable fix.

### D10 · New **composable overlays** rather than editing the base test profiles
**Why:** keep the released/tested `values-test-*` profiles intact and layer durability/portal/callback as
independent `-f` overlays that can be added or dropped. **Alternative rejected:** bake everything into one profile —
harder to review, and couples unrelated concerns (durability vs portal vs callback).

### D11 · `VALIDATE_DID_DOCUMENT` resolved by an **in-cluster did:web resolver shim** (was: DB bridge)

**Problem:** `VALIDATE_DID_DOCUMENT` resolves the new `did:web:*.tx.test` via a Universal Resolver. The public
`dev.uniresolver.io` cannot reach a local `did:web:*.tx.test` (the hosts only resolve inside the cluster, and the
IdentityHub serves `did.json` Host-header-dependently), so the Portal's own credential-request chain stalled here.
The **original demo workaround** was a Portal-DB bridge (mark VALIDATE done, set the credential entries IN_PROGRESS,
insert the AWAIT steps) and drive the credential requests directly on the IH — demo-only, not a code change.

**Fix (removes the bridge):** ship a tiny in-cluster **did:web Universal-Resolver shim** as a value-gated chart
template — `charts/umbrella/templates/didweb-resolver.yaml` (gated by `didwebResolver.enabled`; a Python
`ThreadingHTTPServer` mounted from a ConfigMap on `python:3.12-alpine`, Deployment + Service `didweb-resolver:8080`,
deployed into `.Release.Namespace`). It implements `GET /1.0/identifiers/{did}` for `did:web` only: it fetches
`http://{host}/{path}/did.json` (with `Host: {host}`) over the cluster network and returns the doc in the
Universal-Resolver envelope `{ didDocument, didResolutionMetadata, didDocumentMetadata }` the Portal expects. The
worker points at it via `portal.backend.processesworker.dim.universalResolverAddress: http://didweb-resolver:8080/`
(in the onboarding overlays; renders to `APPLICATIONCHECKLIST__DIM__UNIVERSALRESOLVERADDRESS`).
Verified: the provider's published did:web resolves (HTTP 200 + full `didDocument`, no `didResolutionMetadata.error`)
→ VALIDATE passes with **no bridge**; an unpublished did:web returns `{"error":"notFound"}` → VALIDATE correctly fails.

**Residual (separate from the resolver):** the resolver can only resolve a did:web the IdentityHub has actually
**published**. A cleanly worker-created participant publishes its DID on activation (proven by the seeded provider);
one whose create/activate raced does not (its `/{BPN}/did.json` returns 204), so its DID stays unresolvable until
publishing succeeds. Ensuring worker-driven create→activate reliably publishes the DID is a wallet-creation matter
(portal-backend `IdentityHubService` / the IH publish-on-activate), independent of the resolver — tracked as the one
remaining open item for a fully-clean, bridge-free onboarding.

**If did:web is used in production (what to do instead of the shim):** did:web itself is production-fine — you do
**not** need this shim. In a real deployment the participant DID hosts are publicly reachable over **HTTPS** at
`https://{host}/{optional-path}/did.json` (or `/.well-known/did.json` for a bare host), and a standard Universal
Resolver's `did:web` driver resolves them directly. So: (1) publish each participant's `did:web` on a public HTTPS
host with a valid TLS cert (set `EDC_IAM_DID_WEB_USE_HTTPS=true` on the IdentityHub/connector — the sandbox forces
it to `false` precisely because `*.tx.test` is cleartext-only); (2) **drop** the
`dim.universalResolverAddress` override and point it at a real resolver — the public `https://dev.uniresolver.io/1.0/`
or a self-hosted `decentralized-identity/universal-resolver` (its `uni-resolver-driver-did-web` handles did:web out
of the box). The shim exists **only** because the sandbox's did:web hosts are cluster-internal and served over
cleartext; it is not a did:web limitation. **Alternative rejected:** relax/skip DID validation for the sandbox —
hides a real integration step and diverges the sandbox from production; the shim keeps the exact same Portal code
path exercised.

## What we deliberately did NOT change

- **tractusx-edc / DTR** — used as-is from their branches; the 431 and the DCP flow were fixed via seed/BDRS/config,
  not connector code.
- **The Portal's callback receiver** — reused unchanged (it already accepts an issuer-agnostic response); no new
  Portal endpoint was added for this.

## Upstreaming disposition

- **Upstream candidates:** the identityhub SPI event (`UPSTREAM-ISSUE.md`) + a generalised extension (D1, D3, D4);
  arguably the portal-backend IdentityHub wallet route (D-portal) if the project wants an OSS wallet option.
- **Umbrella/sandbox-only:** the overlays (D9, D10), the seed guard (D8 — until the seed is refactored to a single
  idempotent job upstream), the worker host/SMTP fixes (D6, D7 — umbrella deployment config), and the D11 did:web
  resolver shim (chart template `templates/didweb-resolver.yaml`, gated by `didwebResolver.enabled` — drop it and
  point at a real Universal Resolver in a public deployment).
- **Working rule:** commits carry only the user's identity (DCO `-s`), no AI attribution; `CLAUDE.md` and these
  `docs/internal/*` planning docs stay local (never committed to main).

## Production hardening (sandbox → real deployment)

This stack is a **private repo deployed only to a local kind cluster**, so the items below are deliberately NOT
fixed here — they are the things to do (or avoid) before anything like this runs in a shared/production environment.
They are recorded so the sandbox shortcuts are explicit, not forgotten.

- **Secrets — do not commit; source + rotate.** The pinned IdentityHub super-user key (`EDC_IH_API_SUPERUSER_KEY`,
  a full Identity-API super-user) and the callback client secret are committed as literals across the overlays for
  sandbox convenience. For production: source them from a k8s Secret via the existing `values-external-secrets.yaml`
  path (single owner, rotatable), never commit, and treat any key that ever touched git history as compromised
  (rotate the participant / rewrite history). The adopter overlay already uses a `REPLACE_WITH_*` placeholder for
  the client secret — apply the same to the super-user key.
- **Transport — TLS, not cleartext.** Token acquisition and the Portal callback run over `http://` through the
  ingress; D4 pins the callback client to HTTP/1.1 precisely because h2c-over-cleartext hangs. Production: terminate
  TLS on the ingress for the centralidp token endpoint and the Portal callback host — which also lets HTTP/2
  negotiate over ALPN and retires the D4 pin.
- **did:web resolution — real resolver + egress control.** The `didweb-resolver` shim resolves `did:web:*.tx.test`
  only because those hosts are cluster-internal and cleartext. Production: publish participant DIDs on a public HTTPS
  host (`EDC_IAM_DID_WEB_USE_HTTPS=true`) and point `dim.universalResolverAddress` at a real Universal Resolver
  (`https://dev.uniresolver.io/1.0/` or a self-hosted `decentralized-identity/universal-resolver`). **Note (security
  lens):** did:web inherently fetches attacker-influenceable hosts (a registrant supplies their own DID under
  bring-your-own-wallet #1422), so swapping in a real resolver is necessary but **not sufficient** — the resolver
  must also enforce a host allowlist, refuse redirects, and sit behind an egress `NetworkPolicy`. The shim leaves
  these open on purpose (sandbox); do not carry that forward.
- **Issuance-completion signal — event, not poll.** The observer polls `HolderCredentialRequestStore` every 10s
  (no SPI event exists yet; `UPSTREAM-ISSUE.md` proposes one). Production/upstream target: an EDC
  `HolderCredentialRequestObservable`/`EventRouter` event so the reaction is push-based. **Contested end-state:** a
  fire-once event is lossy across restarts, so the robust design is *event + a durable notified-watermark*, not an
  event that replaces the reconciler — keep the watermark either way.
- **DCP data-exchange provisioning — the STS clientSecret (out of onboarding scope by design).**
  `IdentityHubService.CreateHolderWalletAsync` obtains the holder's STS `clientSecret` only on the 201 create
  (unrecoverable on 409). BE-293 onboarding deliberately does NOT retain it: onboarding's job is to create the wallet,
  issue credentials, and advance the checklist for the company, which makes it a **credential holder**, not a
  data-exchange peer — data
  transfer in the dataspace is exercised by the dedicated provider/consumer connectors, not by onboarded holders, so
  no per-participant connector (and no STS secret) is provisioned here. **If** an onboarded company is later given its
  OWN connector, that connector needs this secret in its Vault (`edc-wallet-secret`) — it must be captured at create
  time (rotate/recreate the participant otherwise) and provisioned directly to that Vault, never persisted in the
  Portal. That is a separate step outside the onboarding flow, not a gap in it.

## Fresh-rebuild validation (2026-07-18) — findings F1–F6

A full from-scratch rebuild (teardown → build 6 images → cluster → Phase 1 → Phase 2 → §7 onboarding)
was run to verify the documented process reproduces the stack. **§1–§6 reproduced GREEN** (DCP data
transfer SUCCEEDED twice; resolver chart-template auto-deployed; extension active; migrations Complete).
The **§7 IdentityHub onboarding** exposed a chain of real gaps — the original demo only "completed"
because DB bridges papered over F5+F6. All blocking gaps are now fixed, and a **clean fresh onboarding
ran the entire credential chain automatically, no nudges**:
`CREATE_IDENTITY_HUB_WALLET → VALIDATE_DID_DOCUMENT → TRANSMIT_BPN_DID → REQUEST_{BPN,MEMBERSHIP}_CREDENTIAL →
AWAIT_*_CREDENTIAL_RESPONSE` all DONE, **2 credentials ISSUED, both callbacks SUCCESSFUL**.

| # | Gap | Layer | Fix | Status |
|---|---|---|---|---|
| **F1** | On a fresh Phase-1 install, connector control- AND data-planes CrashLoopBackOff until their PVC-backed Postgres is Ready; the EDC runtime *exits* on DB-refused at boot (probe-widening doesn't help) and the ~5 min backoff cap stalls self-recovery. | umbrella / k8s | Recovery = `kubectl delete pod` / `rollout restart` the plane pods once the `-db` pods are Running. Documented in runbook §5. | doc |
| **F2** | Runbook §7.1 named the operator `cx-operator`, but the CX-Central seed's operator **username is the UUID** `ac1cf001-7fbc-1f2f-817f-bce058020006` (email `cx-operator@tx.org`). | umbrella / doc | Runbook §7.1 corrected (look up by email → username). | doc |
| **F3** | Portal `bpnDidResolver.managementApiAddress` left at the chart default (`bpn-did-resolution-service-bdrs-server:8081`, nonexistent), API key empty → `TRANSMIT_BPN_DID` fails `Name does not resolve`. The connectors read BDRS via the directory API (`bdrs-server:8082`); the Portal write side was never wired. | umbrella config | Overlay: `portal.bpnDidResolver.managementApiAddress: http://bdrs-server:8081` + `processesworker.bpnDidResolver.apiKey: TEST` (matches `bdrs-server-memory` management authKey). | **fixed + validated** |
| **F4** | Retrigger/recovery wiring is incomplete for the new IdentityHub steps: `RETRIGGER_CREATE_IDENTITY_HUB_WALLET` (810) and `RETRIGGER_TRANSMIT_DID_BPN` are NOT in `IDENTITY_WALLET.GetManualTriggerProcessStepIds()`, and BPNL/MEMBERSHIP_CREDENTIAL retrigger endpoints 400 too — so a *failed* IH-path step can't be operator-recovered. | portal-backend | Latent (only bites on failure, which F3/F5/F6 remove). Recorded for an upstream completion pass — extend the `ApplicationChecklistEntryTypeIdExtensions` manual-trigger maps + add the missing retrigger endpoints. | open (latent) |
| **F5** | The IdentityHub wallet path stored the DID in `CompanyWalletData.Did` but never set `Company.DidDocumentLocation`, which the credential-request `holder` reads → `REQUEST_BPN_CREDENTIAL` fails `ConflictException: The holder must be set`. | portal-backend code | `IdentityHubBusinessLogic.CreateWalletInternal` now `AttachAndModifyCompany(... DidDocumentLocation = did)` (as the DIM/BYOW paths do). Built into `:be293`. | **fixed + validated** |
| **F6** | The onboarded holder is never registered with the IssuerService → the holder's DCP credential request is rejected `401 "ID token verification failed: Participant not found"` → issuance UNSUCCESSFUL. | portal-backend code + umbrella config | `IdentityHubService.RequestCredentialAsync` now registers the holder first (`POST {issuerAdmin}/v1alpha/participants/{issuerCtx}/holders`, idempotent). **Live testing caught a base64-vs-plain ctx bug** — the IssuerService admin API wants the PLAIN ctx (like IH #937), not base64. New settings `IssuerAdmin{BaseAddress,ApiKey}`, `IssuerParticipantId`, `FrameworkContractVersion` wired via the portal chart patch + overlays; IssuerService super-user key pinned in `values-callback-activation.yaml`. | **fixed + validated** |

**Bottom line:** the documented §2–§6 process reproduces the durable stack exactly. §7 onboarding now
completes end-to-end automatically once F3 (config), F5 (code), F6 (code+config) are applied; F4 is a
latent recovery-wiring gap that only matters when a step fails. F1/F2 are documentation corrections.
