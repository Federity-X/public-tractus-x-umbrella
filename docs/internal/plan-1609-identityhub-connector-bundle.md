# Plan — sig-release #1609: IdentityHub + Connector Bundle for Umbrella

> **Issue:** [eclipse-tractusx/sig-release#1609](https://github.com/eclipse-tractusx/sig-release/issues/1609)
> **Milestone:** Tractus-X 26.06
> **Labels:** `tractusx-edc`, `tractusx-identityhub`, `tractus-x-umbrella`, `Prep-R26.06`
> **Owner (us):** @wahidulazam (contributor); committers: @matbmoser, @CDiezRodriguez, @mgarciaLKS
> **Status of this plan:** **2026-06-20 — ALL #1609 VALIDATION STEPS COMPLETE.** Full DCP data-exchange (catalog → negotiation → transfer → fetch) validated end-to-end on **all three** IdentityHub profiles (shared, per-participant, persistent/postgres). See **§0.2** for the authoritative current standing (it supersedes the "What's left" / G2 items in §0.1; §0.1 in turn supersedes the gaps/DoD/version facts further below).
> **Re-plan history:** 2026-06-19 — Test Case 1 passes on the shared profile (**§0.1**). 2026-06-18 — latest-component check + per-participant feasibility (**§0.0**). 2026-04-19 draft v3 — D10 resolved (postgres IssuerService); see `docs/common/concept/1609-local-test-findings.md#phase-11`.

---

## 0.2 — 2026-06-20 update: all validation steps complete (authoritative)

**Supersedes the "What's left" list and the G2 gap row in §0.1.** Since §0.1 the
remaining validation was completed and a third IdentityHub variant was added.
The full DCP data transfer (catalog → contract negotiation → transfer → fetch)
is now validated end-to-end on **all three** IdentityHub profiles:

| Profile (`-f charts/…`)                                       | Topology / store                  | Validated                                   |
| ------------------------------------------------------------- | --------------------------------- | ------------------------------------------- |
| `values-test-data-exchange-identity-hub.yaml`                 | shared in-memory IH               | ✅ clean `helm install` from scratch        |
| `values-test-data-exchange-identity-hub-per-participant.yaml` | one in-memory IH per BPN (4 IHs)  | ✅ provider↔consumer1, each on its own IH   |
| `values-test-data-exchange-identity-hub-postgres.yaml` (NEW)  | persistent IH (PostgreSQL)        | ✅ full transfer                            |

All three run on the EDC-0.17.0-aligned stack via the new image overlay
`values-test-data-exchange-identity-hub-local-0.17.0.yaml` (see §0.1 for the
version gap — the committed `Chart.yaml`s still pin the 0.16.0 line).

**Done since §0.1:**

1. **Clean fresh-install proof** — full transfer green from `helm install` (no
   kubectl patching). Required encoding the working config into the profile:
   PLAIN `participantContextId` + the EDC-0.17.0 `TX_EDC_IAM_DCP_CREDENTIALSERVICE_URL`
   (was base64 / the legacy `TX_IAM_IATP_…` name).
2. **Per-participant topology (G2) — DONE** (was "follow-up" in §0.1). Four
   IdentityHub JVMs fit at ~68% memory on a 7.65 GiB kind node; transfer green.
3. **Persistent (postgres) IdentityHub — NEW + DONE.** Added `tractusx-identityhub`
   (alias `identity-hub-postgres`) as a third mutually-exclusive wallet
   (`_wallet-validate.tpl` is now 3-way: stub | identity-hub | identity-hub-postgres).
   Four postgres-variant fixes: the postgres **label clash** with
   `dataprovider-digital-twin-db` (`postgresql.nameOverride` + jdbcUrl); the
   seed's readiness-wait **pod label**; the IH's different **port layout**
   (identity 8082 / credentials 8083 / did 8084); and — the real blocker — a
   **non-unique `holderPid`** in the seed's credential request. `holderPid` is
   the PRIMARY KEY of the IdentityHub holder-credential-request store; the seed
   sent a constant (`= issuer DID`) for every participant, so on the persistent
   store only the first holder's request inserted and the rest hit a PK
   collision and never issued (the in-memory store tolerated it — a latent bug).
   Fixed with a unique `holderPid` per request: a general seed correctness fix
   that benefits every profile.
4. **Deploy-guide refresh (G6) — DONE.** `docs/user/common/guides/data-exchange-identity-hub.md`
   rewritten for the three profiles, the 0.17.0 stack and the smoke test.
5. **Committed** — `c9e3e2d` (feature) + `659325c` (this plan). Single-author,
   DCO sign-off, no AI attribution; `CLAUDE.md` excluded.

Also hardened since §0.1: the BDRS directory-seeding hook now runs on
`post-upgrade` too, and `hack/dcp-data-transfer-smoke.sh` self-warms the
cold-BDRS-cache first-transfer race (re-negotiates once).

**Only item still open (gated on upstream releases, not on us):** bump the
bundle `Chart.yaml` pins to `tractusx-connector 0.13.0` (EDC 0.17.0) +
IdentityHub/IssuerService 0.17.0 once published, then delete the `-local-0.17.0`
overlay. (Optional: persist the postgres IH's key vault; harden the in-memory
BDRS against restarts.)

---

## 0.0 — 2026-06-18 re-plan: latest-component check + per-participant feasibility

**Trigger:** _"use the latest components; can we now achieve per-participant topology?"_

**Component release check** — Tractus-X `charts/dev` channel, the only channel
these EDC-aligned charts publish to (a `stable`-channel copy does **not** exist
yet; verified `helm search repo tractusx-stable/*` → no results):

| Component                           | Umbrella pin (now) | Latest released                        | Verdict                                                                       |
| ----------------------------------- | ------------------ | -------------------------------------- | ----------------------------------------------------------------------------- |
| `tractusx-identityhub-memory`       | **v0.3.2**         | **v0.3.2** (2026-06-16)                | ✅ already newest                                                             |
| `tractusx-issuerservice` (postgres) | **v0.3.2**         | **v0.3.2**                             | ✅ already newest                                                             |
| `tractusx-connector`                | **0.13.0-rc2**     | `0.12.1` stable · `0.13.0` still `-rc` | ⚠️ on an RC ahead of stable (kept on purpose — DCP-native, matches IH 0.16.0) |
| `bdrs-server-memory`                | 0.6.0              | 0.6.0                                  | ✅ newest                                                                     |
| `digital-twin-registry`             | 0.10.0             | 0.12.0                                 | ⬆️ 2 minors behind (optional housekeeping)                                    |
| `ssi-dim-wallet-stub`               | 0.1.14             | 0.1.18                                 | ⬆️ behind (default path; optional)                                            |

v0.3.2 (2 days old) brings EDC 0.16.0, configurable VC-type scope aliases
(IH #279), custom attestation tables (IH #299) and idempotent issuance
migrations (IH #291). **None of these touch deployment topology.**

**Key conclusion — per-participant is NOT gated on component versions.**
We are already on the newest IdentityHub/IssuerService. Per-participant
topology has been achievable since v0.2.0 and remains a pure **umbrella
Helm-composition** task, not an upstream-version task. The _same_
`tractusx-identityhub-memory` chart we deploy **once** today (shared
multi-tenant: one IH hosting 4 ParticipantContexts) would simply be
instantiated **N times** (one IH per BPN) for per-participant. No newer image
or chart unlocks this — the only blocker is that the umbrella declares a
_single_ IH dependency.

**Concrete per-participant work (supersedes the old "Phase D / G2 = follow-up" framing in §4/§5):**

1. **Instantiate the IH chart per participant** — either (a) add
   `tractusx-identityhub-memory` as an aliased dependency under each
   participant chart (`tx-data-provider`, `dataconsumerOne`,
   `dataconsumerTwo`) plus the operator, or (b) give each participant its own
   Helm release. Approach (a) keeps the single-`helm install` experience.
2. **One ingress host + DID per IH:** `ih-<role>.tx.test` →
   `did:web:ih-<role>.tx.test` (no extra path segment). The per-participant
   profile already declares these four hosts.
3. **Re-point each connector** `credentialservice` + STS at its _own_ IH
   service. The dcp schema is already per-participant — only the URLs change
   from the shared host to the per-role hosts.
4. **Keep ONE shared IssuerService** (Tractus-X = one issuer per dataspace);
   all four IHs trust it (we already fixed `trustedIssuers` → issuer-service
   host this session).
5. **Seeding:** the post-install hook already loops per participant — point
   each iteration at its own IH admin endpoint.
6. **`/etc/hosts` + coredns patch:** add the four `ih-*.tx.test` hosts.

**Practical constraint:** per-participant = **4× IH pods** (+ their probes and
resource requests). On a single kind/minikube node _that_ is the real cost —
not component versions. The shared profile stays the default for functional
testing; per-participant is the "realistic isolation" option.

**Connector version decision:** keep `0.13.0-rc2` for the bundle. It is the
DCP-native line that matches IH/IS v0.3.2 (EDC 0.16.0) and was validated green
end-to-end this session (catalog HTTP 200). Downgrading to stable `0.12.1`
would reintroduce the pre-DCP `iatp:` / `sts.dim:` schema and the STS
mismatch. The only version follow-up worth tracking is "bump to `0.13.0`
final when it leaves `-rc`".

---

## 0.1 — 2026-06-19 current standing: TEST CASE 1 PASSES (authoritative)

**This section supersedes the gap analysis (§4 G1–G6), the runtime assumptions
(§11.4 R1–R3), the Definition of Done (§8), and the connector/IH version facts
in §0/§0.0/§2.** Everything below was proven on a live `kind` cluster
(`umbrella-1609`) with the shared-IdentityHub profile and the
[`hack/dcp-data-transfer-smoke.sh`](../../hack/dcp-data-transfer-smoke.sh)
stage-aware test.

### Result

**Full DCP data transfer works end-to-end** — `catalog → offer`, `contract
negotiation → FINALIZED`, `transfer → EDR cached`, `data address resolved`,
`consumer fetches the provider submodel bytes over DCP` (asserted marker
present). Validated **twice**, the second time on the **stock**
`tractusx/edc-controlplane-postgresql-hashicorp-vault:0.13.0-SNAPSHOT` image —
so **the connector needs ZERO code changes**; the entire solution is
umbrella-side.

### The validated stack vs. the committed pins (THE central remaining gap)

The working configuration was assembled by patching the running deployments;
the committed chart pins still lag it:

| Component         | Committed pin (working tree)      | Stack the transfer was validated on            |
| ----------------- | --------------------------------- | ---------------------------------------------- |
| `tractusx-connector` | `0.13.0-rc2` (EDC 0.16.0)      | **`0.13.0-SNAPSHOT` (EDC 0.17.0)** main-line image |
| IdentityHub / IssuerService | `v0.3.2` (EDC 0.16.0)   | **user's local 0.17.0 build** (PR [tractusx-identityhub#308](https://github.com/eclipse-tractusx/tractusx-identityhub/issues/308), kind-loaded, pullPolicy Never) |

The 0.17.0 alignment is **required**, not cosmetic: EDC 0.17.0 / IH #937
stopped base64url-decoding the `participantContextId` in credential-service URL
paths. On the 0.16.0 stack the connector's catalog-time credential pull is
routed to a base64 CS endpoint that the 0.17.0-shaped seed no longer emits → no
credentials → empty catalog. The seed was ported to **plain** participantContextId
to match 0.17.0. So the committed `v0.3.2` / `0.13.0-rc2` pins + the plain-ctxId
seed are **internally inconsistent**: the bundle only does the full transfer on
the 0.17.0 stack, which is **not yet released**.

### Root cause of the long-standing "empty catalog / failed transfer" — found & fixed (umbrella-side)

The earlier conclusion *"the connector never dispatches the inbound VP pull —
connector-internal bug"* was **disproven** by instrumenting the connector: the
pull fires and succeeds. Two of our own configuration defects were the blockers:

1. **Thin credential claims (the essential fix).** The seed issued every
   credential with `credentialSubject = {id, holderIdentifier}` only. The
   Catena-X 2025/09 policy functions need type-specific claims:
   `FrameworkAgreement` does an exact match on `credentialSubject.contractVersion`
   and `BusinessPartnerNumber` reads a claim whose key ends in `bpn`. Both
   failed → catalog filtered (and the same constraints in the usage policy would
   fail negotiation; `UsagePurpose` is a no-op placeholder; `Membership` is
   presence-only). **Fix (DONE):**
   [`post-install-identityhub-seed.yaml`](../../charts/tx-data-provider/templates/post-install-identityhub-seed.yaml)
   now registers a `holder` attestation, builds **per-type** CredentialDefinition
   mappings (`BpnCredential → credentialSubject.bpn`,
   `DataExchangeGovernanceCredential → contractVersion`), and sets
   `properties.contractVersion` at holder registration. Verified in the live VC
   dump. (Re-package after edits: `helm package charts/tx-data-provider -d charts/umbrella/charts/` — the umbrella renders the `.tgz`, not the source.)
2. **Empty BDRS directory (transfer layer).** The transfer terminated with
   `No BPN entry found for agreement` because the in-memory `bdrs-server`
   directory was empty, so `EventContractNegotiationSubscriber.resolveBpn(did)`
   returned nothing and `TxDataFlowPropertiesProvider` found no consumer BPN.
   The umbrella **already** seeds BDRS via
   [`post-install-bdrs-setup.yaml`](../../charts/umbrella/templates/post-install-bdrs-setup.yaml)
   (the IH profile sets `bdrs-server-memory.seeding.bpnList` to the four
   `did:web:identity-hub.tx.test:<BPN>` entries). The directory was empty only
   because BDRS is in-memory and had restarted ~7× in a long-lived cluster while
   the hook was `post-install`-only. **Fix (DONE):** added `post-upgrade` to the
   hook so upgrades re-seed; a fresh install always covered it. Residual,
   accepted fragility: a BDRS pod restart wipes the in-memory directory until the
   next install/upgrade.

### Gap & DoD status

| Item | Was | Now |
| ---- | --- | --- |
| G1 single source of truth for BPN/DID/keys | HIGH | ✅ `_wallet-derive.tpl` + `wallet.participants`; seed drives everything from it |
| G2 per-participant topology | MEDIUM | ⬜ still shared-only validated; per-participant profile exists, not E2E-tested (follow-up) |
| G3 seeding hook E2E-verified | HIGH | ✅ all participants seeded, all credentials `ISSUED`, full transfer green |
| G4 connector↔IH STS mismatch | HIGH | ✅ STS works (SI-token mint + VP pull both directions, rich claims) |
| G5 dedicated feature branch | LOW | ✅ on `feature/1609-identityhub-connector-bundle` |
| G6 user deploy guide | MEDIUM | 🟡 `docs/user/common/guides/data-exchange-identity-hub.md` exists; needs a refresh for the 0.17.0 stack + smoke test |
| §11.4 R1 DID doc CredentialService entry | runtime-check | ✅ present (plain ctxId) |
| §11.4 R2 STS wire compatibility | tail risk | ✅ compatible on EDC 0.17.0 |
| §11.4 R3 issuance completes | runtime-check | ✅ all VCs reach `ISSUED` |

### What's left

1. **Version release dependency (the blocker to a shippable PR).** The working
   stack needs published artifacts: `tractusx-edc 0.13.0` final (EDC 0.17.0) and
   an IdentityHub/IssuerService 0.17.0 release (PR #308 merged + released). Until
   then the committed pins (`0.13.0-rc2` / `v0.3.2`) produce the *non-working*
   0.16.0 bundle. Bump the pins in
   [`charts/dataspace-connector-bundle/Chart.yaml`](../../charts/dataspace-connector-bundle/Chart.yaml)
   and [`charts/identity-and-trust-bundle/Chart.yaml`](../../charts/identity-and-trust-bundle/Chart.yaml)
   once available, then re-validate with images pulled (not kubectl-patched).
2. **Clean fresh-install proof.** All pieces are validated independently and via
   a wallet-layer re-seed; a single `helm uninstall`/`install` on the 0.17.0
   stack should be run to prove green from scratch (currently the cluster is a
   patched/re-seeded state, not a clean release).
3. **Per-participant topology (G2).** Wire + E2E-test the per-participant profile
   (4 IH pods) — §0.0 has the steps. Follow-up, not a 26.06 blocker.
4. **Docs refresh (G6).** Update the deploy guide for the 0.17.0 stack and point
   at the smoke test as the Test-Case-1 evidence.
5. **Commit hygiene.** Working tree has the seed enrichment + repackaged
   `tx-data-provider-0.5.0.tgz` + BDRS hook + persistence/seed-port fixes +
   `hack/dcp-data-transfer-smoke.sh`, all uncommitted. Commit when ready
   (single-author; never commit `CLAUDE.md` or this plan). Revert any live
   deployments still on the `:debug-vppull` image (already reverted to stock).
6. **Optional robustness.** BDRS in-memory restart fragility (see fix #2) — a
   persistent BDRS variant or a self-healing re-seed would harden it.

---

> **⚠️ Everything from §0 onwards is the ORIGINAL plan (2026-04 → 2026-06-18), kept for history.** Where it conflicts with §0.1 / §0.2 above — e.g. `tractusx-connector 0.11.2` + the `iatp` / `sts.dim` schema (now `0.13.0-rc2`, DCP-native, `dcp` keys), "shared-only / per-participant deferred to 26.09" (per-participant + postgres are done), or "Test Case 1 unproven" (it passes) — **§0.1 / §0.2 are authoritative.**

## 0. TL;DR — Is umbrella-only sufficient?

**Yes.** Closing #1609 requires **zero code changes** to `tractusx-identityhub`,
`tractusx-issuerservice`, or `tractusx-edc`. Everything needed is already
shipped in:

- `tractusx-identityhub-memory` **v0.3.2** (2026-06-16) — _was v0.2.0 when this plan was drafted; see §0.0_
- `tractusx-issuerservice` (postgres) **v0.3.2**
- `tractusx-connector` **0.13.0-rc2** (DCP-native, EDC 0.16.0-aligned) — _was 0.11.2 when this plan was drafted_

What we do need to change lives entirely in **this repo** (umbrella). The
scope boils down to: new Helm value wiring + a post-install seeding Job that
walks the 10-step DCP API sequence documented upstream at
[`tractusx-identityhub/docs/usage/dcp-api-walkthrough/`](https://github.com/eclipse-tractusx/tractusx-identityhub/tree/main/docs/usage/dcp-api-walkthrough).

Caveat — **there are three runtime assumptions we must verify on a live
cluster before opening the PR** (§11 _Validation_). If any of them fail, the
fix is still umbrella-local (values / hook adjustments), except for one
tail risk called out explicitly.

---

## 1. What the issue actually asks for

Verbatim benefits from the issue:

1. **Ready-to-deploy chart in a decentralized manner.**
2. **Synchronize the initial configuration between Identity Hub and Connector.**

**Test Case 1:** _"Attempt a data-exchange, using the umbrella as a reference."_

### Interpretation (what "bundle" means here)

The word "bundle" is deliberately loose in the issue. Reading it against the
umbrella's existing patterns and the upstream repos, the feature splits into
three concrete deliverables:

| #   | Deliverable                                                                                                                                                                        | Where it lives                                                               |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| D1  | A Helm composition that stands up Identity Hub + Issuer Service + a `tractusx-connector` wired to them, with one source of truth for BPN/DID/keys.                                 | `charts/identity-and-trust-bundle` + `charts/tx-data-provider` in this repo. |
| D2  | An umbrella profile (`values-test-data-exchange-identity-hub.yaml`) that swaps the SSI DIM Wallet Stub for the bundle and still passes the existing data-exchange adopter journey. | `charts/values-test-data-exchange-identity-hub.yaml`.                        |
| D3  | Local deploy + E2E data-exchange validation on minikube (or Docker Desktop) — matching Test Case 1.                                                                                | New `docs/user/common/guides/data-exchange-identity-hub.md`.                 |

D1 is the _plumbing_, D2 is the _ready-to-deploy experience_, D3 is the _test
case evidence_. A PR that closes #1609 needs all three.

---

## 2. Upstream state (verified 2026-04-18; **refreshed 2026-06-18 — see §0.0**)

> The table below is the **original 2026-04-18** snapshot, kept for history.
> The current pins advanced to IH/IS **v0.3.2** and connector **0.13.0-rc2**
> (EDC 0.16.0). See §0.0 for the up-to-date version matrix.

| Artifact                        | Version                                                                  | Notes                                                                                   |
| ------------------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------- |
| `tractusx-identityhub`          | `v0.2.0` (2026-03-10)                                                    | 4 chart variants: full + `-memory`, same for Issuer Service.                            |
| `tractusx-identityhub-memory`   | `v0.2.0`                                                                 | No external Vault/PostgreSQL; matches the umbrella's in-memory test posture.            |
| `tractusx-issuerservice-memory` | `v0.2.0`                                                                 | Admin API `/api/admin`, Issuance API `/api/issuance`.                                   |
| `tractusx-connector`            | `0.11.2` (umbrella pin)                                                  | Schema still uses `iatp:` / `sts.dim:`.                                                 |
| `tractusx-connector`            | `0.12.0`                                                                 | Still `iatp:` / `sts.dim:`.                                                             |
| `tractusx-connector`            | `0.13.0-rc1`                                                             | **DCP rename applied:** `dcp:` / `sts.div:` + `didService.selfRegistration` + VP cache. |
| `ssi-dim-wallet-stub`           | `0.1.14` (umbrella pin)                                                  | Stays as the **default** wallet.                                                        |
| Upstream PRs referencing #1609  | **none** in `tractus-x-umbrella`, `tractusx-identityhub`, `tractusx-edc` | We are the first movers.                                                                |

### Schema-rename consequence

Identity Hub v0.2.0 is natively DCP-shaped. The umbrella's current connector
(`0.11.2`) is **pre-rename**. For a working bundle:

- **Short path (pick this):** keep `tractusx-connector` at `0.11.2` and use
  its `iatp:` / `sts.dim:` keys pointing at IH endpoints. IH doesn't care
  what the connector's Helm values schema looks like — it only sees HTTP
  calls on `/api/sts`, `/api/credentials`, and `/api/identity`. _This is
  what's already scaffolded in the current branch._
- **Long path (follow-up):** bump to `tractusx-connector 0.13.0+` when it
  stabilises out of `rc`, rename all `iatp` → `dcp` and `sts.dim` → `sts.div`
  in the umbrella, and enable `didService.selfRegistration`. Track as a
  separate follow-up issue.

---

## 3. What is already in place on this branch

Branch: `feature/1609-identityhub-connector-bundle` (re-scoped from the original `feature/BE-165-umbrella-chart-documentation` — see §7).

Applied and `helm lint`/`helm template`-verified:

- [x] `wallet:` indirection block at the umbrella level — `stub` | `identityHub`. [charts/umbrella/values.yaml](charts/umbrella/values.yaml)
- [x] Mutual-exclusion validator that fails helm render if both wallets enabled. [charts/umbrella/templates/\_wallet-validate.tpl](charts/umbrella/templates/_wallet-validate.tpl), [charts/umbrella/templates/configmap-wallet-mode.yaml](charts/umbrella/templates/configmap-wallet-mode.yaml)
- [x] `tractusx-identityhub-memory v0.2.0` + `tractusx-issuerservice-memory v0.2.0` pinned as optional deps of `identity-and-trust-bundle`. [charts/identity-and-trust-bundle/Chart.yaml](charts/identity-and-trust-bundle/Chart.yaml)
- [x] Default values for both charts that match real v0.2.0 schema (endpoints 8080–8087, two ingresses per IH for presentation + admin planes). [charts/identity-and-trust-bundle/values.yaml](charts/identity-and-trust-bundle/values.yaml)
- [x] Shared-topology profile file. [charts/values-test-data-exchange-identity-hub.yaml](charts/values-test-data-exchange-identity-hub.yaml)
- [x] Per-participant profile (documented target; wiring still missing). [charts/values-test-data-exchange-identity-hub-per-participant.yaml](charts/values-test-data-exchange-identity-hub-per-participant.yaml)
- [x] Post-install seeding hook (`wallet.mode == identityHub`-gated) with real Identity API + Issuer Admin API calls, idempotent (409 → OK), schema-drift-tolerant. [charts/tx-data-provider/templates/post-install-identityhub-seed.yaml](charts/tx-data-provider/templates/post-install-identityhub-seed.yaml)
- [x] Vault pre-seed guarded by `wallet.mode`, writes `identityhub-api-key` + `operator-sts-secret-alias`. [charts/tx-data-provider/templates/post-install-vault-setup.yaml](charts/tx-data-provider/templates/post-install-vault-setup.yaml)
- [x] `ECOSYSTEM-GUIDE.md` §7.y "Choosing a Wallet Implementation" documents the trade-off.

**Verification evidence:**

```text
# default stub mode — ConfigMap renders
helm template umb charts/umbrella
  → tractusx.eclipse.org/wallet-mode: "stub"

# both wallets on — validator fires
helm template umb charts/umbrella --set identity-and-trust-bundle.identity-hub.enabled=true
  → Error: execution error at (umbrella/templates/configmap-wallet-mode.yaml:13:4):
    identity-and-trust-bundle: only one of `ssi-dim-wallet-stub.enabled` or
    `identity-hub.enabled` may be true at a time
```

---

## 4. Honest gaps vs. issue scope

| Gap                                                                                                                                                                                                                                                                                                                                                   | Why it blocks closing #1609                                                      | Severity                                       |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------- |
| **G1. No single source of truth for per-participant BPN/DID/keys.** Currently BPN is declared in `tractusx-connector.iatp.id` AND (separately) in `identity-hub.identityhub.iatp.sts.oauth.client.id`. Operators can desync.                                                                                                                          | Directly contradicts benefit #2 ("synchronize the initial configuration").       | **HIGH**                                       |
| **G2. Per-participant topology only documented, not wired.** `tx-data-provider`/`dataconsumerOne`/`dataconsumerTwo` have no IH sub-dep; the per-participant profile currently can't deploy. **This is an umbrella Helm-composition task, not a component-version one** — see §0.0 for the concrete wiring steps (we are already on the newest IH/IS). | The word "decentralized" in benefit #1 implies each participant runs its own IH. | **MEDIUM** — shared mode covers the test-case. |
| **G3. Seeding hook not E2E-verified.** Payload schemas (`/v1alpha/participants`, `/v1alpha/credentials`) are from v0.2.0 docs but no actual install has completed.                                                                                                                                                                                    | Test Case 1 can't pass without this.                                             | **HIGH**                                       |
| **G4. Connector–Hub STS protocol mismatch.** IH's STS is DCP-native (not OAuth2); `tractusx-connector 0.11.2`'s `sts.dim.oauth.token_url` expects OAuth2. May fail at runtime.                                                                                                                                                                        | Test Case 1 may fail even after seeding.                                         | **HIGH (unknown until E2E)**                   |
| **G5. Branch is scoped to docs.** Current branch name & previous commits imply doc-only.                                                                                                                                                                                                                                                              | A PR referencing #1609 should live on a dedicated feature branch.                | LOW                                            |
| **G6. No user-facing deploy guide.** `docs/user/common/guides/*` has no "run the umbrella with Identity Hub" walkthrough.                                                                                                                                                                                                                             | Issue expects ready-to-deploy experience.                                        | MEDIUM                                         |

---

## 5. Detailed implementation plan

### Phase A — Close G1 (config synchronization) **[2–3 hrs]**

Goal: each participant's identity parameters are declared **once**, and both
connector config and IH ParticipantContext derive from that one place.

1. In `charts/umbrella/values.yaml`, add under `wallet:`:
   ```yaml
   wallet:
     mode: stub
     operatorBpn: "BPNL00000003CRHK"
     participants:
       operator:
         bpn: "BPNL00000003CRHK"
         role: operator
       provider:
         bpn: "BPNL00000003AYRE"
         role: provider
       consumer1:
         bpn: "BPNL00000003AZQP"
         role: consumer
       consumer2:
         bpn: "BPNL00000003AVTH"
         role: consumer
     identityHub:
       topology: shared # shared | perParticipant
       sharedHost: "identity-hub.tx.test"
       didScheme: "did:web"
       didwebHttps: false
   ```
2. New template `charts/umbrella/templates/_wallet-derive.tpl`:
   - `define "umbrella.wallet.didFor"` → returns `did:web:<sharedHost>:<bpn>` (shared) or `did:web:ih-<role>.tx.test` (perParticipant).
   - `define "umbrella.wallet.credentialServiceUrlFor"` → IH `/api/credentials` URL for a participant.
   - `define "umbrella.wallet.stsUrlFor"` → IH `/api/sts` URL.
3. Replace the hand-written DIDs in `values-test-data-exchange-identity-hub.yaml` with `tpl`'d invocations of the helpers (or document the helpers in the profile's header comment — `tpl` across chart boundaries is awkward in umbrella values files).
4. The seeding hook reads `PARTICIPANT_DID` from `.Values...iatp.id`. Keep that — it still holds the derived value.

Acceptance: `diff` the rendered DIDs across three locations (connector
`iatp.id`, BDRS seeding, IH `iatp.sts.oauth.client.id`) for a given
participant — all three must derive from the **same** source key.

### Phase B — Close G3 + G4 (runtime validation) **[half day, gated on cluster]**

1. Install minikube (see §6.1), run the shared-topology profile.
2. Watch the `-post-install-identityhub-seed` Job logs.
3. When (not if) API payloads drift from docs:
   - Compare against `/tmp/ih/tractusx-identityhub-memory/templates/*.yaml` and the IH sample Postman collection ([upstream repo docs/](https://github.com/eclipse-tractusx/tractusx-identityhub)).
   - Adjust the POST bodies in the seeding hook.
4. For G4 (STS mismatch): if the connector can't get SI tokens against
   `/api/sts`, enable the connector's **embedded STS** extension instead
   of the DIM/OAuth2 flow:
   - `tractusx-connector 0.11.2` supports embedded STS via
     `controlplane.environment.EDC_IAM_STS_PRIVATEKEY_ALIAS` +
     friends. Document the precise env vars in the profile.
5. Re-run until the provider can publish an asset and a consumer can
   retrieve it.

Acceptance: `curl` from the dataconsumer-backend container against the
provider's dataplane returns test payload bytes.

### Phase C — Close G6 (deploy guide) **[2 hrs]**

Create `docs/user/common/guides/data-exchange-identity-hub.md`:

- Prereqs link back to existing minikube setup.
- Single-command deploy: `helm install ...-f values-test-data-exchange-identity-hub.yaml`.
- Hosts to add to `/etc/hosts` (`identity-hub.tx.test`, `identity-hub-admin.tx.test`, `issuer-service.tx.test`, etc. — list them explicitly).
- Post-install verification commands (check IH Job log, `curl` a DID document).
- Pointer to Test Case 1 (existing `data-exchange.md`).
- Known-limitations section citing G2 (no per-participant wiring yet) and the connector-version constraint.

### Phase D — Close G2 (per-participant topology)

**2026-06-18 update:** re-scoped from "document only" to an actionable task —
see **§0.0** for the verified finding (no component upgrade required; this is
pure umbrella Helm composition) and the concrete 6-step wiring approach. The
per-participant profile
[charts/values-test-data-exchange-identity-hub-per-participant.yaml](charts/values-test-data-exchange-identity-hub-per-participant.yaml)
stays in-repo as the target end-state; its header comment already documents
the required dependency wiring. Whether it ships in the first #1609 PR or a
follow-up is a sequencing call (§9 open question 2), **not** a technical
blocker.

### Phase E — Close G5 (branch + PR hygiene) **[30 min]**

1. `git checkout -b feature/1609-identityhub-connector-bundle`.
2. `git cherry-pick` or `git restore --source=...` the relevant commits from
   the current branch, keeping the doc-only commits on the original branch.
3. Open PR titled
   `feat(bundle): add Identity Hub + Connector wallet option (refs #1609)`.
4. PR description: link #1609, link to this plan file, summarize scope of
   first PR (shared topology only, stub remains default), list the four
   explicit follow-ups.

---

## 6. Local deploy + test (macOS, ARM)

### 6.1 Cluster bootstrap (one-time)

```bash
# already installed: helm, kubectl
brew install minikube

minikube start \
  --cpus=6 --memory=10g --disk-size=40g \
  --kubernetes-version=v1.30.0 \
  --addons=ingress,ingress-dns

MINIKUBE_IP=$(minikube ip)

# /etc/hosts entries needed for the bundle profile on top of the usual umbrella hosts
sudo tee -a /etc/hosts <<EOF
${MINIKUBE_IP}  identity-hub.tx.test
${MINIKUBE_IP}  identity-hub-admin.tx.test
${MINIKUBE_IP}  issuer-service.tx.test
${MINIKUBE_IP}  issuer-service-admin.tx.test
EOF
```

Plus all the usual umbrella hosts from [docs/user/mac/without-docker-desktop.md](docs/user/mac/without-docker-desktop.md).

### 6.2 Install the umbrella with Identity Hub

```bash
cd ~/projects/public-tractus-x-umbrella

# build chart deps (already done in previous session, safe to repeat)
helm dependency build charts/identity-and-trust-bundle
helm dependency build charts/tx-data-provider
helm dependency build charts/umbrella

kubectl create namespace umbrella || true

helm install umbrella charts/umbrella \
  -f charts/values-test-data-exchange-identity-hub.yaml \
  --namespace umbrella \
  --timeout 20m \
  --wait=false

# watch rollout
kubectl -n umbrella get pods -w
```

### 6.3 Verify the seeding

```bash
# IH pod healthy
kubectl -n umbrella logs -l app.kubernetes.io/name=tractusx-identityhub-memory --tail=50

# Seeding Job ran
kubectl -n umbrella get jobs
kubectl -n umbrella logs job/umbrella-tx-data-provider-post-install-identityhub-seed

# DID document resolvable
curl -s http://identity-hub.tx.test/BPNL00000003AYRE/did.json | jq .
# expected: a DID document with verificationMethod for key-1

# Participant listed in IH
curl -s -H "X-Api-Key: sup3r\$3cr3t" \
  http://identity-hub-admin.tx.test/api/identity/v1alpha/participants | jq .

# VC issuance request enqueued at the issuer
kubectl -n umbrella logs -l app.kubernetes.io/name=tractusx-issuerservice-memory --tail=100 | grep -iE "credential|issuance"
```

Expected state: 4 ParticipantContexts in IH (operator + provider + 2
consumers), 3 credentials per participant in state `ISSUED`.

### 6.4 Test Case 1: execute a data exchange

Follow existing guide: [docs/user/common/guides/data-exchange.md](docs/user/common/guides/data-exchange.md).

```bash
# Provider publishes an asset (as per existing guide)
# Consumer performs contract negotiation + transfer
# Success criterion: consumer fetches asset bytes from provider's dataplane
```

If contract negotiation fails with `IATP auth failed` or similar:

- Dump controlplane env: `kubectl -n umbrella exec deploy/umbrella-dataconsumerone-controlplane -- env | grep -i iatp`
- Check that `EDC_IAM_IATP_CREDENTIALSERVICE_URL` is the IH presentation URL, not the stub.
- Consult Phase B §4 (STS mismatch fallback).

### 6.5 Teardown

```bash
helm uninstall umbrella -n umbrella
kubectl delete namespace umbrella
minikube stop
```

---

## 7. Risks

| #   | Risk                                                                                                   | Mitigation                                                                                              |
| --- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| R1  | IH Identity API payload schema drifted between v0.2.0 and what the docs show.                          | Seeding hook logs HTTP status + body and continues on unknown status; operator inspects after install.  |
| R2  | `tractusx-connector 0.11.2` can't obtain SI tokens from IH's STS because the connector expects OAuth2. | Phase B §4 — embedded STS fallback documented in the profile.                                           |
| R3  | `tractusx-connector 0.13.0` stabilises during 26.06 and the community prefers the DCP-renamed bundle.  | Keep `iatp`/`dcp` schema decoupling tight (profile comments), open a follow-up issue for the 0.13 bump. |
| R4  | Minikube resource pressure on a 16 GB laptop (we requested 10 GB).                                     | Umbrella `values-test-data-exchange.yaml` disables observability stack; profile inherits this.          |
| R5  | IngressDNS entries drift across macOS / Linux / Windows.                                               | §6.1 keeps `/etc/hosts` as the source of truth; ingress-dns is optional.                                |

---

## 8. Definition of Done (for a PR that closes #1609)

- [ ] Phase A merged (single source of truth for participants).
- [ ] Phase B proven: `helm install ... -f values-test-data-exchange-identity-hub.yaml` completes on a clean minikube; all IH pods `Ready`; seeding Job succeeds; Test Case 1 passes (asset transferred end-to-end).
- [ ] Phase C merged (user-facing deploy guide).
- [ ] Phase E merged (branch split, PR opened, linked to #1609).
- [ ] SSI DIM Wallet Stub remains the **default**; existing CI/E2E not regressed.
- [ ] Follow-up issue opened for Phase D (per-participant topology).
- [ ] Follow-up issue opened for `tractusx-connector 0.13` / DCP schema rename.

---

## 9. Open questions (before opening the PR)

1. Does the Tractus-X community expect the "bundle" to live inside the
   **umbrella** (our interpretation) or as a new chart in the
   `tractusx-identityhub` repo that both the umbrella and standalone users
   can consume? → Ask @AYaoZhan / @matbmoser on #1609.
2. Is the shared-IH topology acceptable for a "first" bundle, or must
   per-participant ship in the same PR? → Bias toward "shared first", but
   confirm.
3. Which connector version should the 26.06 bundle target — `0.11.2` (stable,
   pre-DCP) or `0.13.x` (DCP-native, rc only as of 2026-04-18)? → Likely
   whichever stabilises first; propose `0.12.0` bump as interim if 0.13
   slips.

---

## 10. Command cheat-sheet for this work-item

```bash
# rebuild + lint after any chart change
helm dependency build charts/identity-and-trust-bundle && \
helm dependency build charts/tx-data-provider && \
helm dependency build charts/umbrella && \
helm lint charts/umbrella -f charts/values-test-data-exchange-identity-hub.yaml

# render only the new templates to eyeball them
helm template umb charts/umbrella \
  -f charts/values-test-data-exchange-identity-hub.yaml \
  --show-only charts/identity-and-trust-bundle/charts/tractusx-identityhub-memory/templates/deployment.yaml

# quick loop: re-seed without full reinstall
kubectl -n umbrella delete job umbrella-tx-data-provider-post-install-identityhub-seed
helm upgrade umbrella charts/umbrella \
  -f charts/values-test-data-exchange-identity-hub.yaml \
  --namespace umbrella --reuse-values

# grab IH logs
kubectl -n umbrella logs -l app.kubernetes.io/name=tractusx-identityhub-memory -f
```

---

## 11. Plan validation — deep dive (2026-04-18 re-review)

This section records a second-pass validation of the plan against upstream
v0.2.0 docs at
[`tractusx-identityhub/docs/usage/dcp-api-walkthrough/`](https://github.com/eclipse-tractusx/tractusx-identityhub/tree/main/docs/usage/dcp-api-walkthrough)
and the IH/IS v0.2.0 Helm charts. It lists what the initial plan (and the
already-scaffolded seeding hook) got **wrong** or **under-specified**, and
the umbrella-local fix for each. **No finding in this section requires a
change to any upstream repo.**

### 11.1 Can this be done without touching IH/IS/connector code? — Yes.

| Surface our bundle depends on                                                    | Ships in                               | Status                          |
| -------------------------------------------------------------------------------- | -------------------------------------- | ------------------------------- |
| `POST /api/identity/v1alpha/participants` (create ParticipantContext)            | IH v0.2.0 + IS v0.2.0                  | ✅ Present                      |
| `PUT /api/identity/v1alpha/participants/{id}/state?isActive=true`                | IH + IS v0.2.0                         | ✅ Present                      |
| `GET /.well-known/did.json` served by IH's DID endpoint (port 8083)              | IH v0.2.0                              | ✅ Present                      |
| `POST /api/admin/v1alpha/participants/{id}/attestations`                         | IS v0.2.0                              | ✅ Present                      |
| `POST /api/admin/v1alpha/participants/{id}/credentialdefinitions`                | IS v0.2.0                              | ✅ Present                      |
| `POST /api/admin/v1alpha/participants/{id}/holders`                              | IS v0.2.0                              | ✅ Present                      |
| `POST /api/identity/v1alpha/participants/{id}/credentials/request` (DCP trigger) | IH v0.2.0                              | ✅ Present                      |
| `POST /api/sts` (OAuth2 token + SI-token mint)                                   | IH v0.2.0                              | ✅ Present                      |
| Connector-side `iatp.sts.oauth` wiring                                           | Connector 0.11.2                       | ✅ Present                      |
| Connector-side CS-URL resolution via DID doc `service[]`                         | Connector 0.11.2 DCP runtime extension | ⚠️ Runtime-check (see §11.4.R2) |

**Bottom line for the user's question:** everything listed above is already
released. The work is 100% configuration + orchestration inside the umbrella.

### 11.2 Corrections required in the already-scaffolded seeding hook

The upstream DCP walkthrough specifies a **10-step** bootstrap flow. Our
current hook implements only 2 of those steps, and two of them are wrong.
The table below is authoritative for the rewrite.

| #   | Step (upstream name)          | Endpoint & verb                                                        | Where  | Current hook state                                                                                           |
| --- | ----------------------------- | ---------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------ |
| 1   | Create Issuer Participant     | `POST {IS}/api/identity/v1alpha/participants`                          | Issuer | ❌ Missing                                                                                                   |
| 2   | Create Holder Participant     | `POST {IH}/api/identity/v1alpha/participants`                          | Holder | ⚠️ Has POST but wrong body (see §11.3)                                                                       |
| 3   | Activate Participant Contexts | `PUT {…}/api/identity/v1alpha/participants/{id}/state?isActive=true`   | Both   | ❌ Missing                                                                                                   |
| 4   | Verify DID Documents          | `GET {…}/.well-known/did.json` (+ per-participant path)                | Both   | ⚠️ Poll exists but does not verify `service[]` entry                                                         |
| 5   | Create Attestation            | `POST {IS}/api/admin/v1alpha/participants/{id}/attestations`           | Issuer | ❌ Missing                                                                                                   |
| 6   | Create Credential Definition  | `POST {IS}/api/admin/v1alpha/participants/{id}/credentialdefinitions`  | Issuer | ❌ Missing                                                                                                   |
| 7   | Register Holder at Issuer     | `POST {IS}/api/admin/v1alpha/participants/{id}/holders`                | Issuer | ❌ Missing                                                                                                   |
| 8   | Request Credentials (DCP)     | `POST {IH}/api/identity/v1alpha/participants/{id}/credentials/request` | Holder | ❌ **Wrong path used today** — hook POSTs `/api/admin/v1alpha/credentials` which does not exist in IH v0.2.0 |
| 9   | Retrieve Credentials          | `GET {IH}/api/identity/v1alpha/participants/{id}/credentials`          | Holder | ❌ Missing (needed for idempotent re-run + Test Case 1 gating)                                               |
| 10  | Verify Credential             | client-side                                                            | —      | N/A                                                                                                          |

### 11.3 Authentication: `x-api-key` is **runtime-generated**, not our constant

The upstream `00_prerequisites.md` is explicit:

> When both services start, the `SuperUserSeedExtension` generates a
> super-user participant context and prints the API key to the logs:
> `[SuperUserSeedExtension] Super-user API key: c3VwZXItdXNlcg==.xxxxxxxxxxxx`

And:

> The API key encodes both the participant context and the authorization
> token. The part before the first `.` is the base64url-encoded participant
> ID. Format: `x-api-key: <participant-context-id>.<token>`

Consequences for our hook:

1. The `sup3r$3cr3t` / `authKeyAlias` value in the chart's
   `identityhub.endpoints.identity.authKeyAlias` is **not** the super-user
   key. It is a Vault alias under which IH stores a **per-endpoint** API
   key. The super-user key that authorises creating new participants is
   emitted at runtime to stdout.
2. Our seeding hook must either:
   - **(A)** `kubectl logs` the IH/IS pods, grep out
     `Super-user API key:`, and use that — requires a ServiceAccount + RBAC
     to read pod logs. Cleanest but couples the hook to the kube-api.
   - **(B)** Pre-seed the super-user key into Vault **before** IH/IS start
     (via an `install` hook with higher weight than the IH/IS deploy) so
     that `SuperUserSeedExtension` finds the existing key instead of
     generating one. Requires checking whether v0.2.0 supports this override
     path (the `identityhub.iatp.sts.oauth.client.*` block hints it does,
     but that block is for the **initial participant**, not the super-user).
   - **(C)** Use the chart's `iatp.sts.oauth.client.enabled: true` to
     bootstrap the first participant via Helm values (= operator/issuer
     context), and create the other 3 via the API using a per-participant
     API key obtained as part of the first create-response.

   **Recommendation:** **(A)** for the first PR. It is the shortest path
   and mirrors what a human integrator would do following the upstream
   walkthrough. `(B)`/`(C)` are Phase-D refinements.

Required RBAC if we pick (A):

```yaml
# tx-data-provider/templates/post-install-identityhub-seed-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "txdataprovider.fullname" . }}-ih-seed
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list"]
```

### 11.4 Runtime assumptions to verify on first live install

| #   | Assumption                                                                                                                                                                                                                    | Impact if false                                                                               | Umbrella-local fix available?                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| R1  | IH v0.2.0 emits a DID document at `/{participantId}/did.json` containing a `service[]` entry with `type: "CredentialService"` whose `serviceEndpoint` points back to IH's `/api/credentials/v1/participants/{ctxId}`.         | Connector (verifier) can't discover holder's CS → DCP presentation fails → Test Case 1 fails. | **Yes** — the `serviceEndpoints[]` array is supplied _by the caller_ in the `POST /participants` body (confirmed in walkthrough step 2). Our hook must include it.                                                                                                                                                                                                                                                                                     |
| R2  | Connector 0.11.2's `iatp.sts.oauth` flow (OAuth2 client-credentials against `token_url`) is wire-compatible with IH's `/api/sts` token endpoint.                                                                              | Connector cannot mint SI tokens → protocol never gets past authentication.                    | **Probably yes** via `iatp.sts.oauth.token_url: http://identity-hub…/api/sts/token` + `iatp.sts.dim.url: http://identity-hub…/api/sts`. **Tail risk:** if connector 0.11.2 hard-codes a DIM-specific request body that IH's STS rejects, we must either bump to connector 0.13.0-rc1 (DCP-native) **or** enable the connector's embedded STS and use IH only as CS+VC-holder. Both options are umbrella-local values changes; no upstream code change. |
| R3  | IS v0.2.0's issuance flow, once attestation + credentialdefinition + holder are registered, responds synchronously to `POST /participants/{id}/credentials/request` and delivers the VC into IH's store within a few seconds. | Seeding Job times out; subsequent `GET /credentials` returns empty → Test Case 1 can't start. | **Yes** — Job polls step 9 with exponential backoff; IS emits issuance-process state via `GET {IS}/api/admin/v1alpha/participants/{id}/issuanceprocesses/query`; we can use that endpoint for observability.                                                                                                                                                                                                                                           |

### 11.5 Port numbers — the chart and the walkthrough disagree

The chart's defaults put STS on `8087` and Identity on `8081`; the walkthrough
text refers to STS `8085` and Identity `8086`. The **chart is authoritative
at runtime** (it writes `web.http.sts.port` into `identityhub-config` from
chart values). Our profile must use the chart's numbers. The walkthrough's
numbers are illustrative for a non-Helm dev setup.

✅ Current profile already uses chart defaults. No change.

### 11.6 Updated Phase B (supersedes §5 Phase B in the original plan)

Phase B (runtime validation) expands to:

1. Install umbrella with the IH profile on minikube.
2. `kubectl logs deploy/…-identityhub-memory | grep "Super-user API key"` →
   save as `IDH_ADMIN_KEY`.
3. Same for IS → `ISSUER_ADMIN_KEY`.
4. **Rewrite the seeding hook** to run all 10 steps with retries, using the
   RBAC + in-pod `kubectl logs` pattern from §11.3.
5. For each participant in `values.wallet.participants`:
   - Compute `did:web:<host>:<bpn>` (shared topology).
   - Compute base64url of `participantId` → used as context id in CS URL.
   - POST Step 2 with `serviceEndpoints` containing `type: CredentialService`
     and `serviceEndpoint: http://<ih-host>/api/credentials/v1/participants/<ctxId>`.
   - PUT Step 3 to activate.
   - GET Step 4 to verify DID doc is served and contains the `service[]` entry.
6. On the Issuer side, run Steps 5 → 6 → 7 once per credential type
   (Membership, DataExchangeGovernance, FrameworkAgreement).
7. Per holder, run Step 8 and poll Step 9 until all three credentials are
   in state `ISSUED`.
8. **Only then** exit the Job successfully — this guarantees a green Test Case 1.

### 11.7 Amendment to Definition of Done (§8)

Add:

- [ ] Seeding Job implements all 10 DCP walkthrough steps (§11.2).
- [ ] Super-user API key sourcing documented and working (§11.3).
- [ ] DID documents for all 4 participants verified to contain the
      `CredentialService` service entry (§11.4 R1).
- [ ] Issuance processes end in state `ISSUED` for all 3 credential types
      per holder before Job succeeds.

### 11.8 Tail risk — only scenario that could require an upstream PR

If §11.4 R2 fails (connector 0.11.2 STS request body incompatible with IH
STS), and connector 0.13.0 is still `rc` at PR time, **and** the embedded-STS
workaround is not viable, the only remaining option is to backport a small
DCP-STS adapter into `tractusx-edc 0.11.x`. That would be an upstream PR in
`eclipse-tractusx/tractusx-edc`, **not** in the identity hub. Probability:
low — OAuth2 client-credentials is a standard enough surface that we expect
compatibility. We will know after Phase B §5 attempt 1.

---

## 12. Answer to the question "do we need identityhub codebase changes?"

**No.** The work fits entirely inside this repo:

- Helm wiring & new profile values → `charts/umbrella`, `charts/identity-and-trust-bundle`, `charts/tx-data-provider`.
- 10-step seeding Job → `charts/tx-data-provider/templates/post-install-identityhub-seed.yaml` (rewrite).
- ServiceAccount + Role for reading super-user API keys from IH/IS pod logs → new small manifest in `tx-data-provider`.
- Optional follow-up: `charts/umbrella/templates/_wallet-derive.tpl` helper for the single source of truth (Phase A).

The only scenario that forces an upstream PR is the narrow tail risk in
§11.8, and it would land in `tractusx-edc` (connector), not in
`tractusx-identityhub`. That risk can be retired by a single live install
in Phase B before we commit to a PR strategy.

---

## 13. Alignment with the Tractus-X 26.06 release

> **Milestone:** [Release 26.06](https://github.com/eclipse-tractusx/sig-release/milestone/14) · **Due:** 17 June 2026 · **Scope:** 46 issues (1 closed, 45 open as of 2026-04-18)

### 13.1 Release calendar (sig-release/milestone/14)

The sig-release repo tracks phase issues but the bodies are empty
(auto-created). The dates visible in the milestone view are:

| Phase                                                   | Target window                  | Our relevance                                                              |
| ------------------------------------------------------- | ------------------------------ | -------------------------------------------------------------------------- |
| Refinement Phase (#1373)                                | Now → **Draft Feature Freeze** | Land §5 Phase A (config sync), get #1609 PR in draft.                      |
| Draft Feature Freeze (#1374)                            | mid-May 2026                   | #1609 PR must be open and referenced.                                      |
| Alignment Day (#1375)                                   | late May 2026                  | Present local-deploy evidence (Test Case 1 pass) to committers.            |
| FOSS - Feature Freeze (#1381)                           | early June 2026                | All umbrella wiring + seeding Job rewrite must be merged.                  |
| FOSS - Int Deployment (#1382)                           | early June 2026                | Umbrella main branch must render + install cleanly with both wallet modes. |
| FOSS - Kick-off Testing (#1383) / Testing Phase (#1384) | early-to-mid June 2026         | Fix any E2E regressions surfaced against stable EDC 0.11 → 0.12 bump.      |
| Release Closing (#1388) → Publish (#1390)               | 17 June 2026                   | Bundle profile documented as "preview" if #1610 (portal) slips.            |

Concrete deadline for us: **#1609 PR merged before FOSS Feature Freeze (#1381)**, roughly ~6 weeks from today.

### 13.2 The 26.06 issues that touch our work

Only 4 of the 26 feature issues in 26.06 matter for #1609:

| Issue     | Title (abbrev.)                                                         | Dependency direction                                                                                                                                              | Committers                                                        |
| --------- | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| **#1609** | [Identity Hub][Connector] Create a bundle for IdentityHub and Connector | **this plan**                                                                                                                                                     | @matbmoser, @CDiezRodriguez, @mgarciaLKS, @AYaoZhan               |
| **#1610** | Upgrade the Portal with SSI IssuerService to support the Identity Hub   | **#1609 enables #1610.** Portal backend replaces `ssi-credential-issuer` with IssuerService calls; our umbrella bundle is what the Portal CI will deploy against. | @matbmoser, @mgarciaLKS, @CDiezRodriguez, @AYaoZhan, @saudkhan116 |
| **#1474** | [Identity Hub] Develop frontend for Identity Hub                        | Consumes our IH deployment; no coupling to umbrella wiring.                                                                                                       | @matbmoser, @mgarciaLKS, @pjuaristi-ikerlan                       |
| **#1612** | IRS — Implement support of EDC 0.11 and above                           | **Independent of #1609** but confirms EDC 0.11 is the 26.06 connector baseline. Reinforces our decision to pin connector `0.11.2` in this bundle.                 | @max-wies-cofinity, @stephanbcbauer                               |

Issues that don't touch #1609 but share the "wallet ecosystem" theme (informational only): #1475 (PCF/DPP attestation VC PoC), #1477 (multi-dataspace credentials), #1564 (policy JSON Schema validation — connector-side), #1611 (TCK automation in umbrella — same committers).

### 13.3 Critical coupling: #1609 → #1610

[#1610](https://github.com/eclipse-tractusx/sig-release/issues/1610) is a **downstream consumer** of our bundle. Its benefits are:

> Replace `ssi-credential-issuer` with the `IssuerService` component.
> Working IssuerService that complies with DCP.

The Portal team (same committer set) will rewire `WalletService.cs` to call the **IssuerService Admin API** (`/api/admin/v1alpha/…`) that our bundle seeds. If our seeding contract drifts from what #1610's backend expects, both issues slip.

**Action for this plan:** once Phase B is green, post the exact seeded shape (attestations, credentialdefinitions, holders registered) to #1609 so the Portal team can code against it.

### 13.4 Recommended execution window

Keeping the 17-June cut-off in mind:

```
Week -1 (now)      Finish Phase A wiring (§5), open draft PR on #1609.
Weeks 0-1          Phase B local run on minikube; fix seeding Job per §11.2.
                   Publish seeded shape contract as a comment on #1609 for #1610 team.
Weeks 2-3          Phase C (deploy guide), harden profile for CI umbrella-test.
Week 3             Mark PR ready for review.  Flag §11.8 tail risk if it materializes.
Week 4             FOSS Feature Freeze (#1381) — must be merged.
Weeks 5-6          FOSS testing phase buffer; react to regressions only.
```

### 13.5 Scope discipline for 26.06

**In scope** for the #1609 PR that targets 26.06:

- Shared-IH topology only (4 participants on 1 IH memory chart + 1 IS memory chart).
- Connector stays pinned at **0.11.2** (matches IRS baseline from #1612).
- Stub wallet remains the default; bundle is opt-in via `-f values-test-data-exchange-identity-hub.yaml`.
- Seeding Job performs all 10 DCP walkthrough steps idempotently.
- Deploy guide in `docs/user/common/guides/data-exchange-identity-hub.md`.

**Out of scope** for 26.06 (track as follow-ups):

- Per-participant IH topology (Phase D in §5) → target 26.09.
- Bump to `tractusx-connector 0.13.x` + DCP schema rename → target 26.09 after 0.13 stabilises.
- Non-memory IH variant with external PostgreSQL + Vault → target 26.12.
- Identity Hub frontend wiring (#1474) → owned by LKS Next / Ikerlan team, consumes our bundle.

### 13.6 Open coordination points (to raise on #1609)

1. **Confirm the bundle lives in `tractus-x-umbrella`**, not in `tractusx-identityhub` as a new chart. (Our read of the issue; worth an explicit ACK from @matbmoser.)
2. **Agree the seeded contract shape** (which attestations, which credentialdefinitions, what schemas) so the Portal rewrite in #1610 is deterministic.
3. **Confirm connector 0.11.2 / IH 0.2.0 STS compatibility** before FOSS Feature Freeze — our Phase B is exactly this test, but a heads-up from @CDiezRodriguez would save a week if he already has an answer.
4. **PR titles + cross-links:** follow sig-release convention — the PR body must include `Refs eclipse-tractusx/sig-release#1609` so the milestone tracker picks it up.
