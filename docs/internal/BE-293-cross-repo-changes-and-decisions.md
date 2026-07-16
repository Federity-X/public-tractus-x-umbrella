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

### D11 · Onboarding demo uses **DB bridges** around the DID-validation step (sandbox-only)
**Why:** `VALIDATE_DID_DOCUMENT` resolves the new `did:web:*.tx.test` via the PUBLIC `dev.uniresolver.io`, which
cannot reach a local did:web → the Portal's own credential-request chain stalls. To show the callback, we bridge
in the Portal DB (mark VALIDATE done, set the credential entries IN_PROGRESS, insert the AWAIT steps) and drive
the credential requests directly on the IH. **This is demo-only, not a code change.** **Proper fix (removes all
bridges):** run an in-cluster Universal Resolver and point `APPLICATIONCHECKLIST__DIM__UNIVERSALRESOLVERADDRESS`
at it (or relax the validation for the sandbox) so `did:web:*.tx.test` resolves. Tracked as an open item.

## What we deliberately did NOT change

- **tractusx-edc / DTR** — used as-is from their branches; the 431 and the DCP flow were fixed via seed/BDRS/config,
  not connector code.
- **The Portal's callback receiver** — reused unchanged (it already accepts an issuer-agnostic response); no new
  Portal endpoint was added for this.

## Upstreaming disposition

- **Upstream candidates:** the identityhub SPI event (`UPSTREAM-ISSUE.md`) + a generalised extension (D1, D3, D4);
  arguably the portal-backend IdentityHub wallet route (D-portal) if the project wants an OSS wallet option.
- **Umbrella/sandbox-only:** the overlays (D9, D10), the seed guard (D8 — until the seed is refactored to a single
  idempotent job upstream), the worker host/SMTP fixes (D6, D7 — umbrella deployment config), and the D11 bridge
  (delete once a local Universal Resolver exists).
- **Working rule:** commits carry only the user's identity (DCO `-s`), no AI attribution; `CLAUDE.md` and these
  `docs/internal/*` planning docs stay local (never committed to main).
