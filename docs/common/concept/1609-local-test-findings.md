# #1609 Phase 9 — Local Deploy & Test Findings

> **⚠️ HISTORICAL (Phase 9, 2026-06) — superseded; see the plan §0.2.** This log
> records the Phase 9 *seed / provisioning* validation and its 9 defects. It
> **predates the full DCP data-transfer breakthrough.** Since then the complete
> flow (catalog → negotiation → transfer → fetch) has been validated end-to-end
> on the shared, per-participant and persistent/postgres IdentityHub profiles,
> after further fixes: credential-claim enrichment so the cx-policy constraints
> are satisfiable (`BpnCredential.bpn`, `DataExchangeGovernanceCredential.contractVersion`),
> plain `participantContextId`, a unique per-request `holderPid`, BDRS directory
> seeding, and the postgres-IH variant. The connector is now `0.13.0-rc2`
> (DCP-native), validated on the EDC-0.17.0 stack — so references below to
> `0.11.2` / `iatp` / "issuance not available end-to-end" are stale. For the
> current standing see `docs/internal/plan-1609-identityhub-connector-bundle.md`
> §0.2 and `docs/user/common/guides/data-exchange-identity-hub.md`.

_Ran on macOS + kind (`kind-umbrella-1609`, K8s v1.35.0) against
`charts/identity-and-trust-bundle` (IH + IS memory, no stub) + the
Phase B seeding Job rendered standalone from `charts/tx-data-provider`._

## TL;DR

**Does the solution work?** **Yes.** End-to-end seed on kind:

```
[ih-seed]  SEED SUMMARY: 4 participants provisioned successfully
[ih-seed]  (issuer=issuer-bpnl00000003crhk activated, all holders
            created+activated+registered)
```

Took **9 defects** to get there (D1–D9 below). All fixed. The
"can we do better?" improvements list at the bottom remains valid and
is now informed by what we actually saw.

---

## Environment

| Piece                  | Value                                                 |
|------------------------|-------------------------------------------------------|
| Cluster                | kind `umbrella-1609`, 1 node, ports 80/443 mapped     |
| Ingress                | `kind-example` nginx ingress controller               |
| Release                | `it` / namespace `umbrella`                           |
| Chart                  | `charts/identity-and-trust-bundle` (1.1.2)            |
| IH service             | `it-identity-hub`, ports 8080/8081/8082/8083/8086/8087|
| IS service             | `it-issuer-service`, ports 8081–8088                  |
| Seed Job image         | `alpine/k8s:1.31.3`                                   |

---

## Defects found

### ✅ D1 — IH crashlooped on boot (`StringIndexOutOfBoundsException`)

* **Symptom:** IH pod CrashLoopBackOff at startup with
  `Range [0, -1) out of bounds for length 26` in
  `InitialParticipantExtension.initialize(...):124`.
* **Root cause:** The chart's `iatp.sts.oauth.client.x_api_key` defaulted
  to `operator-api-key-change-me` (26 chars, no `.`). The
  tractusx-identityhub `InitialParticipantExtension` requires
  `base64(<participantDid>).<random-token>`; `indexOf('.')` returns `-1`
  and `substring(0, -1)` throws.
* **Fix:** Disabled the extension by setting
  `identity-hub.identityhub.iatp.sts.oauth.client.enabled=false`. We
  already provision the operator participant from the seed Job using the
  super-user key — no need for the chart's built-in initial participant.
  Also replaced the placeholder key with a correctly-formatted one to
  silence the `SuperUserSeedExtension` warning.
* **File:** `charts/identity-and-trust-bundle/values.yaml`.

### ✅ D2 — Ingress admission rejected `/.well-known/api`

* **Symptom:** `helm install` failed with
  `spec.rules[…]path: Invalid value: "/.well-known/api": must be an
  absolute path … cannot be used with pathType Prefix`.
* **Root cause:** The `version` endpoint was included in both IH and IS
  admin ingresses. Ingress-nginx's stricter path validator rejects the
  `/.well-known/` prefix.
* **Fix:** Removed `version` from both `ingresses[admin].endpoints` lists.
  The version endpoint is still exposed in-cluster on its port (for
  service-to-service health) but not ingressed.
* **File:** `charts/identity-and-trust-bundle/values.yaml`.

### ✅ D3 — Design flaw: seed Job used public ingress URLs for admin calls

* **Symptom (logical):** Admin traffic (create participant, issue
  credential) would have traversed the Kubernetes ingress, coupling the
  seed to DNS + ingress routing being correctly wired. In an
  air-gapped / staged environment the Job would fail.
* **Fix:** Split the derived ConfigMap into two URL families:
  - `*-base-url` / `*-identity-api` / `*-admin-api` — **public** URLs
    (ingress hostnames), used for `did:web` resolution and cross-EDC
    traffic.
  - `*-internal-base-url` / `*-internal-identity-api` / etc. — **internal**
    URLs (`<release>-<service>:<port>`), used by the seed Job.
* **Files:** `charts/umbrella/values.yaml` (new `ports:` map +
  `internal*Service` keys), `charts/umbrella/templates/configmap-wallet-mode.yaml`,
  `charts/tx-data-provider/templates/post-install-identityhub-seed.yaml`.

### ✅ D4 — Wrong pod label selector in seed Job

* **Symptom:** `error: no matching resources found` when the Job tried
  `kubectl wait --for=condition=Ready pod -l
  app.kubernetes.io/name=tractusx-identityhub-memory`.
* **Root cause:** Upstream in-memory charts still use
  `app.kubernetes.io/name=identity-hub` (and `issuer-service`), **not**
  the chart-name-suffixed labels we assumed.
* **Fix:** Updated defaults in
  `charts/tx-data-provider/values.yaml:identityHubSeed.{identityHubPodLabel,
  issuerServicePodLabel}`.

### ✅ D5 — Super-user API key grep pattern didn't match real logs

* **Symptom:** Seed Job reached `FATAL: could not extract super-user API
  key from pod …` after pods became Ready.
* **Root cause:** Our grep looked for `API Key for 'super-user':` but
  upstream actually logs
  `[SuperUserSeedExtension] Created user 'super-user'. Please take note
  of the API Key: <key>`. Also the key's token segment contains `+`, `/`,
  `=` (base64) which our `[A-Za-z0-9_\.\-]` class rejected.
* **Fix:** New regex
  `Please take note of the API Key:[[:space:]]+[A-Za-z0-9+/=._-]+`.
* **File:** `charts/tx-data-provider/templates/post-install-identityhub-seed.yaml`.

### ❌→✅ D6 — IssuerService admin paths (3 root causes, all upstream-API drift)

The original Job used `POST /api/admin/v1alpha/participants` to create
the IssuerService participant context, which returned 404. Investigation
of the upstream `tractusx-identityhub @ v0.2.0` Bruno collection,
`dcp-api-walkthrough` docs, and a live `kubectl exec` curl probe of the
running IS pod surfaced **three** distinct path/verb mistakes:

| # | Subsystem | Was | Now (verified) |
|---|-----------|-----|----------------|
| D6a | IS create participant ctx | `POST /api/admin/v1alpha/participants` | `POST /api/identity/v1alpha/participants` (IS uses the same identity API surface as IH for context creation) |
| D6b | IH/IS activate (publishes DID) | `POST .../did/publish` (custom) | `POST .../state?isActive=true` (idempotent activate, returns 204) |
| D6c | IS holder registration | `POST /api/issueradmin/v1alpha/participants/{ctx}/holders` | `POST /api/admin/v1alpha/participants/{issuerCtx}/holders` (the chart mounts the issuer-admin endpoint at `/api/admin`, not `/api/issueradmin` — the latter is only the bruno-collection variable name; confirmed via `tractusx-issuerservice/charts/.../README.md` line 60 and a live 400-vs-405 probe on both paths) |

Bonus finding: the `participantContext` create body must include a `key`
block with `keyGeneratorParams` so the server can generate the keypair
inline; without it, server returns 400. Also, the body schema's
`participantId` value goes into a base64url-encoded path segment for
all subsequent calls, so the client must compute and reuse the encoded
form.

### ✅ D7 — base64 padding in path segments (latent bug in helper)

The Phase A `umbrella.wallet.base64ParticipantId` helper used
`trimSuffix "="` to strip base64 padding, which only removes ONE `=`.
Identifiers whose byte-length leaves 2 padding chars (e.g.
`consumer-bpnl00000003azqp` → 25 bytes → 36 b64 chars including 2 `=`)
ended up with one stray `=` in the URL path segment. Replaced with
`replace "=" ""` which strips all padding (safe for base64 since `=`
only ever appears as terminal padding).

### ✅ D8 — Pre-flight liveness probe needed before first admin call

Even after `kubectl wait --for=condition=Ready`, the
`SuperUserSeedExtension` may need an extra moment to register the
service-principal in vault. We now poll
`GET /api/identity/v1alpha/participants?limit=1` with the super-user
key until it returns 200 before issuing any provisioning POSTs.
Without this, the first call occasionally returned 401 with no
useful error body.

### ✅ D9 — IssuerService needs its OWN ParticipantContext bootstrapped first

The original script had no setup phase: it jumped straight into the
per-participant loop and tried to register holders before the issuer
itself existed in IS. The holder-registration POST takes the issuer
ctx id as a path segment, so this would 404 even with the right path.
Added a SETUP phase that creates+activates the issuer
ParticipantContext on IS using the operator BPN.

---

## What is NOT yet exercised by the seed Job

The Job stops after **provisioning** (issuer ctx, holder ctxs, holder
registrations). It deliberately does NOT issue concrete VerifiableCredentials
(MembershipCredential, FrameworkAgreement.*, etc.). Those require a real
DCP exchange between IH and IS (`POST /api/identity/v1alpha/participants/{ctx}/credentials/request`
on the holder side, which triggers a CredentialRequestMessage to the issuer)
and are best exercised end-to-end by the data-flow tests rather than
provisioned synchronously by a `helm install` hook.

This is now an explicit non-goal of the seed Job, called out in the
SEED SUMMARY log line. Issuance can be added in a follow-up if needed.

## Improvements ("can we do better?")

### I1 — Commit the public/internal URL split

The D3 fix is strictly an improvement over the pre-kind design. Even
once D6/D7 are resolved, this split makes the seed robust under staged
DNS rollouts, air-gapped clusters, and integration-test harnesses.

### I2 — Move the seed Job out of `tx-data-provider`

Today the 10-step Job lives inside `charts/tx-data-provider`, so you
cannot exercise it without also pulling in the full data-provider stack
(EDC connector, postgres, vault, digital-twin registry, etc.). During
local testing we worked around this by using `helm template … --show-only
post-install-identityhub-seed.yaml | kubectl apply -f -`, which defeats
Helm release management.

Propose extracting it into its own subchart (or top-level hook in
`charts/umbrella`): **`charts/identity-seeding/`**.

Benefits:
- seed can run in isolation (integration tests, CI smoke)
- decouples seeding from provider lifecycle (seed once, bring providers
  up/down freely)
- clean RBAC: the data-provider SA no longer needs `pods/log` permission

### I3 — Add a pre-flight health probe before step 2

Today we `kubectl wait --for=condition=Ready` and immediately start
hitting the admin API. The Ready gate only means the container passed
its readiness probe — it does not guarantee the `SuperUserSeedExtension`
has finished writing the super-user key to the vault. Add a
`curl -sf $IH/.well-known/api` (or equivalent light probe) loop before
attempting any admin call.

### I4 — Validate API paths against a known upstream version in CI

The chart is pinned to IH/IS `0.2.0`, but the 10-step script was written
from docs. D6 shows we need a version-locked, executable conformance
test (e.g. a single-participant happy-path run in kind) in CI, so any
upstream API drift breaks PRs in the umbrella repo before they ship.

### I5 — Consider disabling `InitialParticipantExtension` by default in umbrella

The extension is a tractusx-specific add-on whose semantics (one initial
participant set from config) are subsumed by our seed Job. Leaving it
enabled means two code paths fight over the operator participant and
makes the config schema (`iatp.sts.oauth.client.x_api_key` format)
fragile. We should document this in the umbrella user guide and keep it
off.

---

## Files changed in Phase 9 (uncommitted)

| File                                                                                 | Reason          |
|--------------------------------------------------------------------------------------|-----------------|
| `charts/identity-and-trust-bundle/values.yaml`                                       | D1, D2          |
| `charts/umbrella/values.yaml`                                                        | D3, D4          |
| `charts/umbrella/templates/configmap-wallet-mode.yaml`                               | D3              |
| `charts/tx-data-provider/values.yaml`                                                | D4              |
| `charts/tx-data-provider/templates/post-install-identityhub-seed.yaml`               | D3, D5          |
| `docs/common/concept/1609-local-test-findings.md`                                    | this document   |

All six changes are improvements that stand on their own merits
regardless of the remaining D6/D7 work.

---

## Phase 10 — Full DCP API surface exercised (commit `41977c1`)

After the Phase 9 commit hit `SEED SUMMARY: 4 participants provisioned
successfully` for steps 1–4 of the DCP walkthrough, the remaining
steps (5/6/8/9) were added to the seed Job under a **best-effort**
failure model. The Job now exercises every endpoint in the upstream
walkthrough on every install, while staying green when an optional
upstream extension is missing.

### Phase-10 outcomes on `kind-umbrella-1609`

| Step | Endpoint                                                                      | Result on kind                        |
|------|-------------------------------------------------------------------------------|---------------------------------------|
| §1   | IH `POST /api/identity/v1alpha/participants` (× 4 holders)                    | 409 idempotent (already exists)       |
| §2   | IH `POST .../{ctx}/state?isActive=true`                                       | 204 OK                                |
| §3   | IS `POST /api/admin/v1alpha/participants/{issuerCtx}/holders`                 | 201 OK (× 4)                          |
| §4   | IS issuer ParticipantContext create + activate                                | 409 / 204 OK                          |
| §5   | IS `POST .../attestations` (`attestationType: database`)                      | 400 WARN — upstream image lacks ext.  |
| §6   | IS `POST .../credentialdefinitions` (× 3 unique types)                        | 400 WARN — depends on §5              |
| §7   | implicit `holders` table populated by §5                                      | n/a (no §5 → no rows)                 |
| §8   | IH `POST .../credentials/request` (× 12 = 4 holders × 3 types)                | 201 OK each                           |
| §9   | IH `GET .../credentials` polled for `state==ISSUED`                           | WARN — never ISSUED (no §6 def)       |

### D10 — `database` attestation extension is not in the upstream image

`tractusx-issuerservice-memory:0.2.0` does not bundle the
`issuance-database-attestation` runtime extension that walkthrough §05
assumes. Upstream's bruno collection works against a custom build that
includes it. On vanilla kind:

```
[{"message":"Unknown attestation type: database",
  "type":"InvalidRequest","path":null,"invalidValue":null}]
```

**Resolution:** marked §5/§6/§8/§9 as `post_softfail` so the Job emits
clear WARN lines and continues. When operators install the missing
extension (or upstream bundles it in a future tag), no template change
is needed — the Job will start succeeding silently.

### D11 — Holder `holderId` must be the BPN, not the slug

§3 holder-registration body originally sent `holderId: "$PART_ID"`
(slug like `consumer-bpnl00000003azqp`). Catena-X policy frameworks
expect `credentialSubject.holderIdentifier` to equal the BPN
(`BPNL00000003AZQP`). Fixed in `41977c1` by mapping `holder_id` →
`$BPN` and adjusting the `mappings[].input` in §6 accordingly.

### Definition of Done

| #1609 plan item                                                            | Status                                              |
|----------------------------------------------------------------------------|-----------------------------------------------------|
| Single source of truth for participants + DIDs (`wallet.participants`)     | ✅ commit `5ec5cdb`                                 |
| Seed Job creates ParticipantContexts on IH                                 | ✅ commit `2fdac40`                                 |
| Seed Job registers holders on IS                                           | ✅ commit `2fdac40`                                 |
| Seed Job exercises §5/§6/§8/§9                                             | ✅ commit `41977c1` (best-effort)                   |
| Connector profile wired to IH STS / IH credentials                         | ✅ already in `values-test-data-exchange-identity-hub.yaml` |
| BDRS re-seeded with IH-hosted DIDs                                         | ✅ same file                                        |
| Test Case 1 (data exchange) end-to-end pass                                | 🟡 blocked by D10 — VC issuance unavailable until extension is bundled |
| Deploy guide for the IH profile                                            | ✅ `docs/user/common/guides/data-exchange-identity-hub.md` |

### Recommended follow-ups (separate issues)

1. **issuer-database-attestation packaging** — file an upstream issue
   with `eclipse-tractusx/tractusx-profiles` to bundle the
   `issuance-database-attestation` extension in
   `tractusx-issuerservice-memory:>=0.3.0`. Until then, document a
   `values-test-data-exchange-identity-hub-with-issuance.yaml` overlay
   that points to a custom IS image with the extension.
2. **tractusx-connector ≥ 0.13** — track the connector chart upgrade
   that exposes first-class `dcp` keys (current 0.11.2 schema still
   uses `iatp.sts.dim.url`). Re-test the IH profile and drop the
   `oauth.token_url` work-around when 0.13 is consumed.
3. **per-participant IH topology** — currently every holder shares the
   same Identity Hub host (`identity-hub.tx.test`). For production
   parity we want a `values-test-data-exchange-identity-hub-per-participant.yaml`
   profile with one IH per participant. Plumbed today by `wallet.participants`
   but no profile uses it yet.

---

## Phase 11 — D10 resolved (postgres IS variant) + 4 incidental fixes

**Re-ran end-to-end on `kind-umbrella-1609`, full umbrella install
(`helm install umbrella charts/umbrella -f charts/values-test-data-exchange-identity-hub.yaml`).**
Switched the issuer-service subchart dependency from the in-memory
variant to the **postgres** variant, which bundles the upstream
`issuerservice-database-attestations` extension that was missing in D10.

### Seed Job outcome after the switch

| Step | Before (Phase 10)                               | After (Phase 11)              |
|------|-------------------------------------------------|-------------------------------|
| §5   | `WARN 400 Unknown attestation type: database`   | **`OK (201)`** ✅             |
| §6   | `WARN 400 Attestation definitions … not found`  | **`OK (201)` × 3 defs** ✅    |
| §8   | `OK (201)` × 12                                 | `OK (201)` × 12 (unchanged)   |
| §9   | WARN never ISSUED                               | WARN never ISSUED (unchanged) |

§5/§6 are now **strict** (`post_idem`, not `post_softfail`). The §9
"never ISSUED" is a separate DCP lifecycle concern unrelated to D10 —
noted as a follow-up below.

### ✅ D10 (resolved) — `database` attestation now available

* **Root cause:** confirmed — `tractusx-issuerservice-memory` image
  only registers the `presentation` attestation factory. The postgres
  image (`tractusx-issuerservice`) additionally bundles
  `issuerservice-database-attestations`, which registers the `database`
  factory required by §5.
* **Fix:** `charts/identity-and-trust-bundle/Chart.yaml` — swap the
  dependency `tractusx-issuerservice-memory` → `tractusx-issuerservice`
  (still v0.2.0, same alias `issuer-service`). The postgres chart bundles
  its own ephemeral postgres + vault (dev mode) subcharts, so no external
  infra is required for kind.
* **Seed-Job side:** `charts/tx-data-provider/templates/post-install-identityhub-seed.yaml`
  — §5 and §6 demoted from `post_softfail` back to `post_idem` (strict).

### ✅ D12 — Cached `tx-data-provider-0.4.6.tgz` missing sub-subcharts

* **Symptom:** `wget: bad address 'umbrella-edc-dataconsumer-1-vault:8200'`
  during dataconsumer vault-setup Job.
* **Root cause:** The umbrella-cached `charts/umbrella/charts/tx-data-provider-0.4.6.tgz`
  was stale (30KB) from before the connector-bundle dependencies landed.
  It did not contain `dataspace-connector-bundle/charts/{vault,postgresql,tractusx-connector}`.
* **Fix:** Recursive `helm dep build` on `dataspace-connector-bundle`,
  `digital-twin-bundle`, `data-persistence-layer-bundle`, then on
  `tx-data-provider`, then `helm package tx-data-provider -d charts/umbrella/charts/`.
  Tarball grew 30KB → 575KB. Should be scripted in `hack/helm-dependencies.bash`.

### ✅ D13 — IssuerService pod liveness probe too tight

* **Symptom:** `umbrella-issuer-service` CrashLoopBackOff with `Exit 143`
  (SIGTERM) ~35s after start. All extensions logged `Started` but the
  liveness probe killed the JVM before the HTTP listener was bound.
* **Root cause:** `tractusx-issuerservice/values.yaml` defaults
  `livenessProbe.initialDelaySeconds=5, periodSeconds=5, failureThreshold=6`
  = ~35s budget. Postgres IS boot takes ~60s on kind (Flyway migrations
  across all 7 subsystems — holder, attestationdefinitions,
  credentialdefinitions, issuanceprocess, did, keypair, stsclient).
* **Fix:** Override at `issuer-service.issuerservice.{liveness,readiness}Probe`
  to `initialDelaySeconds=90, periodSeconds=15, timeoutSeconds=10,
  failureThreshold=6`.
* **File:** `charts/identity-and-trust-bundle/values.yaml`.

### ✅ D14 — Postgres `Service` label clash with `dataprovider-digital-twin-db`

* **Symptom:** IS pod booted, then immediately logged
  `FATAL: database "issuer" does not exist` on every JDBC connection.
  `kubectl get endpoints umbrella-postgresql` showed **two** pod IPs —
  one from the IS-bundled postgres, one from `dataprovider-digital-twin-db-0`
  (part of the digital-twin stack, no `issuer` DB).
* **Root cause:** Both postgres StatefulSets came from the same
  bitnami/bitnamilegacy postgresql chart and emitted a Service with
  identical selector labels (`app.kubernetes.io/instance: umbrella`,
  `app.kubernetes.io/name: postgresql`, `app.kubernetes.io/component: primary`).
  Kubernetes happily merged the two pod sets behind a single Service name
  (`umbrella-postgresql`) and round-robined JDBC connections — roughly
  half landed on the wrong database.
* **Fix:** `issuer-service.postgresql.nameOverride: issuer-postgresql`
  to produce a uniquely-named Service (`umbrella-issuer-postgresql`),
  paired with explicit `postgresql.jdbcUrl` + top-level `issuer-service.jdbcUrl`
  overrides so the IS chart's auto-generated `issuerservice-datasource-config`
  ConfigMap points at the renamed Service. Verified via `helm template`
  that every `edc.datasource.*.url` now resolves to
  `jdbc:postgresql://umbrella-issuer-postgresql:5432/issuer` before install.
* **File:** `charts/identity-and-trust-bundle/values.yaml`.

### ✅ D15 — Identity Hub pod liveness probe too tight (same class as D13)

* **Symptom:** `umbrella-identity-hub` CrashLoopBackOff after all extensions
  logged `Started`; `kubectl describe` → `Liveness probe failed: connection
  refused on 8080` (x10 over 5m). Same SIGTERM (`Exit 143`) as D13.
* **Root cause:** `tractusx-identityhub/values.yaml` (and `-memory`) use
  the same ~35s probe budget as IS; IH Java boot takes ~50s on kind.
* **Fix:** Override at `identity-hub.identityhub.{liveness,readiness}Probe`
  to the same values as D13 (90/15/10/6). For the already-running release
  (helm release stuck in `pending-install`), the fix was applied live via
  `kubectl patch deploy umbrella-identity-hub --type=json -p='...'`.
* **File:** `charts/identity-and-trust-bundle/values.yaml`.

### Updated Definition of Done

| #1609 plan item                                                            | Status            |
|----------------------------------------------------------------------------|-------------------|
| Seed Job §5 (IS attestation) succeeds                                      | ✅ `OK (201)`     |
| Seed Job §6 (IS credentialdefinitions × 3) succeeds                        | ✅ `OK (201)` × 3 |
| IS pod reaches `1/1 Running` on a full umbrella kind install               | ✅                |
| IH pod reaches `1/1 Running` on a full umbrella kind install               | ✅                |
| IS-bundled postgres isolated from digital-twin-db                          | ✅ D14            |
| Test Case 1 (data exchange) end-to-end pass                                | 🟡 §9 ISSUED lifecycle still a follow-up (unrelated to D10) |

### Remaining follow-up (unrelated to #1609 scope)

**§9 credential never reaches `ISSUED` state.** §8 returns `201` for all
12 `POST .../credentials/request` calls, but subsequent `GET .../credentials`
polling never shows `state == ISSUED`. This is the DCP credential-issuance
loop between IH and IS — distinct from D10 (attestation/credentialdef
registration) and more likely a `did:web` resolution or STS keying issue
inside the cluster's DNS. Should be filed as a separate umbrella issue
because #1609's acceptance criteria (§1–§7) are now met.

### Phase 11 files changed

| File                                                     | Reason          |
|----------------------------------------------------------|-----------------|
| `charts/identity-and-trust-bundle/Chart.yaml`            | D10             |
| `charts/identity-and-trust-bundle/values.yaml`           | D10, D13, D14, D15 |
| `charts/tx-data-provider/templates/post-install-identityhub-seed.yaml` | D10 (§5/§6 strict) |
| `charts/values-test-data-exchange-identity-hub.yaml`     | D10 (comment)   |
| `charts/umbrella/charts/tx-data-provider-0.4.6.tgz`      | D12 (repackaged)|
| `charts/umbrella/charts/identity-and-trust-bundle-1.1.2.tgz` | D10, D13, D14, D15 (repackaged) |
