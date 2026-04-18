# #1609 Phase 9 — Local Deploy & Test Findings

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
