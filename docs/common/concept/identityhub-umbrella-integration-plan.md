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

> Per-repository task breakdown for replacing the SSI DIM wallet stub with a
> real, decentralized IdentityHub-based wallet in the Tractus-X Umbrella
> deployment.

## 1. Executive summary

The umbrella chart currently uses `ssi-dim-wallet-stub` (a memory-only fake
SAP-DIM wallet) for DCP credential presentation. To replace it with a real
decentralized wallet (`tractusx-identityhub`), changes are needed across
**5 repositories**. None of the gating work lives in `eclipse-edc/Connector`
or `eclipse-edc/IdentityHub`; both upstream projects already provide
everything DCP needs. The work is concentrated in the Tractus-X distribution
layer and the umbrella chart itself.

A working end-to-end Docker reference exists outside Eclipse Tractus-X
([Federity-X/public-tractusx-edc#dcp-v2](https://github.com/Federity-X/public-tractusx-edc/tree/dcp-v2/deployment/local)
and
[Federity-X/public-tractusx-identityhub#dcp-flow-local-deployment-with-upstream-0.15.1](https://github.com/Federity-X/public-tractusx-identityhub/tree/dcp-flow-local-deployment-with-upstream-0.15.1)),
plus a Helm-layer attempt on PR
[`tractus-x-umbrella#396`](https://github.com/eclipse-tractusx/tractus-x-umbrella/pull/396).
This plan extracts what needs to land **upstream** and where.

## 2. Architecture target

| Component | Role | Source |
|---|---|---|
| Per-participant **IdentityHub** + Vault + Postgres | DID + VC wallet, presentation API, STS | `eclipse-tractusx/tractusx-identityhub` |
| Shared **IssuerService** | Issues `MembershipCredential`, `BpnCredential`, `UsagePurposeCredential`, `DataExchangeGovernanceCredential` | `eclipse-tractusx/tractusx-identityhub` |
| Central **BDRS** | BPN ↔ DID directory | `eclipse-tractusx/bpn-did-resolution-service` |
| Tractus-X **EDC connectors** (CP+DP) per participant | DSP, contracts, transfers | `eclipse-tractusx/tractusx-edc` |
| Umbrella chart | Composition + deployment profile | `eclipse-tractusx/tractus-x-umbrella` |

The Eclipse EDC layer (`eclipse-edc/Connector`, `eclipse-edc/IdentityHub`) is
**wallet-agnostic** at the protocol level and requires **no changes** for this
integration.

## 3. Per-repository task breakdown

### 3.1 `eclipse-edc/Connector` — ❌ no changes needed

DCP authentication, presentation verification, and SI-token validation are
wallet-agnostic upstream. Service-entry registration to the participant's
DID Document is **not** an upstream concern — it is delegated through the
Tractus-X-specific `DidDocumentServiceClient` SPI (see §3.4).

### 3.2 `eclipse-edc/IdentityHub` — ❌ no changes needed

Already at **v0.17.0** (latest). The Identity Admin API
(`/v1alpha/participants/{ctx}/dids/{did}/endpoints`) is stable. OAuth2 auth
on this API was added in v0.16.0 (PR
[#880](https://github.com/eclipse-edc/IdentityHub/issues/880)). Tractus-X
just needs to consume it.

### 3.3 `eclipse-tractusx/tractusx-identityhub` — 🟡 4 tasks

Owns the Tractus-X-distribution Helm charts for IdentityHub and IssuerService.

| # | Task | Status | Tracking |
|---|---|---|---|
| **3.3.1** | **Templated ConfigMap names** so two IH instances can coexist in one namespace. | 🟡 In review (milestone `26.06`). 26/28 CI green; Copilot 63-char DNS-label suggestion outstanding. | [#257](https://github.com/eclipse-tractusx/tractusx-identityhub/issues/257) / [PR #258](https://github.com/eclipse-tractusx/tractusx-identityhub/pull/258). Bumps charts to **v0.2.1**. |
| **3.3.2** | **Apply Copilot 63-char-truncation fix** on PR #258 (`printf "%s-config" \| trunc 63 \| trimSuffix "-"` helper). | ❌ Not done. | Same PR #258. |
| **3.3.3** | **Stabilize `initial-participant-context` extension** so `service` entries on the seeded DID Document (CredentialService URL, DSP DataService URL) are configurable from `values.yaml`. This is the lever that lets the umbrella avoid runtime DID-document mutation entirely. | 🟡 Module exists (added ~2 months ago, commit *feat: implement initial-participant-context module for identityhub*); needs explicit values-driven `services[]` schema, idempotent seeding, and chart `initialParticipantContext.services:` block. | New issue + PR (not opened yet). |
| **3.3.4** | **Publish `tractusx-issuerservice` and `tractusx-issuerservice-memory` chart variants** to `https://eclipse-tractusx.github.io/charts/dev` so umbrella can consume them without `file://` paths. | 🟡 Charts exist in repo; verify they are released to the chart registry alongside `tractusx-identityhub`. | Release pipeline check. |

### 3.4 `eclipse-tractusx/tractusx-edc` — 🟢 optional, not on critical path

| # | Task | Status | Tracking |
|---|---|---|---|
| **3.4.1** | **`DidDocumentServiceIdentityHubClient`** — implementation of the `DidDocumentServiceClient` SPI for IdentityHub, alongside the existing DIM client. Adds `tx.edc.did.service.client.type={dim\|identityhub}` selector. | 🟢 Reference impl exists in [Federity-X/public-tractusx-edc#7](https://github.com/Federity-X/public-tractusx-edc/pull/7) / [#8](https://github.com/Federity-X/public-tractusx-edc/pull/8). lgblaumeiser asked author to **rebase onto IH 0.16.0 (OAuth2 IssuerAdmin)** before upstreaming. Issue **stale**. | [#2678](https://github.com/eclipse-tractusx/tractusx-edc/issues/2678) — EDC Board, R26.06 bundle ([sig-release #1609](https://github.com/eclipse-tractusx/sig-release/issues/1609)). |
| **3.4.2** | **Helm chart values** in `tractusx-connector` / `tractusx-connector-memory` for IH client section (`identityHub.identityApiUrl`, `identityHub.participantContextId`, `identityHub.identityApiKeyAlias`). | 🟢 Already part of PR #8. | Same. |

> **Why this is optional for the umbrella path.** With §3.3.3 in place, the IH
> chart seeds the DID Document including its DSP service entries at
> `helm install` time. The connector never needs to call the IH Identity
> Admin API to mutate its own DID Document. `tx.edc.did.service.self.registration.enabled=false`
> (the default) is sufficient. #2678 is needed only for non-GitOps adopters
> who require runtime DSP-URL changes.

### 3.5 `eclipse-tractusx/bpn-did-resolution-service` — ✅ done

| # | Task | Status |
|---|---|---|
| **3.5.1** | Release **0.6.0** with EDC 0.16.0 (includes `EDC_IAM_CREDENTIAL_REVOCATION_MIMETYPE` support and Postgres 18). | ✅ Released ~2 weeks ago (`fee8860`). Replaces the `0.7.0-SNAPSHOT` workaround used in PR #396. |
| 3.5.2 | Confirm `bdrs-server-memory:0.6.0` chart is published to the dev chart registry. | ✅ Charts versioned alongside the release. |

### 3.6 `eclipse-tractusx/tractus-x-umbrella` — 🔴 5 tasks (the actual integration)

This is where the bulk of the deliverable sits. It depends only on §3.3 and §3.5.

#### 3.6.1 Add IdentityHub as a feature-flagged dependency in `identity-and-trust-bundle`

`charts/identity-and-trust-bundle/Chart.yaml` (currently v1.1.3, only depends
on `ssi-dim-wallet-stub` 0.1.17) becomes:

```yaml
dependencies:
  - name: ssi-dim-wallet-stub
    version: 0.1.17
    repository: https://eclipse-tractusx.github.io/charts/dev
    condition: ssi-dim-wallet-stub.enabled
  - name: tractusx-identityhub
    version: ">=0.2.1"   # waits on §3.3.1 + §3.3.2
    repository: https://eclipse-tractusx.github.io/charts/dev
    condition: tractusx-identityhub.enabled
  - name: tractusx-issuerservice
    version: ">=0.2.1"   # waits on §3.3.4
    repository: https://eclipse-tractusx.github.io/charts/dev
    condition: tractusx-issuerservice.enabled
```

`values.yaml` adds a single switch and templated enablement of subcharts:

```yaml
identityProvider:
  type: wallet-stub        # wallet-stub | identityhub
ssi-dim-wallet-stub:
  enabled: '{{ eq .Values.identityProvider.type "wallet-stub" }}'
tractusx-identityhub:
  enabled: '{{ eq .Values.identityProvider.type "identityhub" }}'
```

This contrasts with [PR #396](https://github.com/eclipse-tractusx/tractus-x-umbrella/pull/396),
which hard-disabled the stub and used `file://` chart paths. A feature flag
keeps existing wallet-stub adopters untouched.

#### 3.6.2 Use `initialParticipantContext` instead of post-deploy DID-document writes

When `identityProvider.type=identityhub`, the bundle templates the IH's
`initialParticipantContext` block with **service entries** populated from the
connector's ingress hostname (which the umbrella already controls). After
helm install, the DID Document is already complete:

```yaml
tractusx-identityhub:
  initialParticipantContext:
    participantId: '{{ .Values.participant.bpn }}'
    did: 'did:web:{{ .Values.participant.identityHubHost }}:{{ .Values.participant.bpn }}'
    services:
      - id: dataservice-1
        type: DataService
        serviceEndpoint: 'https://{{ .Values.participant.controlplaneHost }}/api/v1/dsp'
      - id: credentialservice-1
        type: CredentialService
        serviceEndpoint: 'https://{{ .Values.participant.identityHubHost }}/api/credentials/v1/participants/{{ b64encDid }}'
```

This eliminates the 12-step manual Bruno run that PR #396 required.

#### 3.6.3 Replace the Bruno issuance run with a post-install Job

Port the credential-issuance steps from
[`Federity-X/public-tractusx-edc/dcp-v2/deployment/local/scripts/bootstrap.sh`](https://github.com/Federity-X/public-tractusx-edc/blob/dcp-v2/deployment/local/scripts/bootstrap.sh)
(steps that talk to IssuerService, **not** the DID-document steps) into a
Helm post-install Job analogous to the existing
[`charts/tx-data-provider/templates/post-install-job-upload-testdata.yaml`](../../../charts/tx-data-provider/templates/post-install-job-upload-testdata.yaml).
Idempotent, mounted from a ConfigMap, re-runnable on `helm upgrade`.

Issues:
- IssuerService participant + attestation + credential-definition setup
  (4 VC types: `MembershipCredential`, `BpnCredential`,
  `UsagePurposeCredential`, `DataExchangeGovernanceCredential`).
- Holder registration (one per participant).
- Credential issuance request per holder per VC type.
- BDRS seeding (BPN ↔ DID).

#### 3.6.4 Add a new adopter values profile

`charts/umbrella/values-adopter-data-exchange-identityhub.yaml`, modelled on
the existing `values-adopter-data-exchange.yaml`, but:
- Sets `identityProvider.type: identityhub` per participant.
- Templates per-participant blocks via YAML anchors instead of duplicating
  ~150 lines per participant (PR #396's 322-line file collapses to ~120).
- Points `bdrs-server-memory` to **published 0.6.0**, drops the
  `nameOverride: bdrs-server` hack.

#### 3.6.5 Documentation

Add a section in
[`docs/user/common/guides/`](../../user/common/guides/) describing the
identity-provider switch, prerequisites, and the post-install issuance Job
flow. Cross-link from §11 of the development setup guide ("Replacing the
Wallet Stub with a Real Identity Hub").

## 4. Dependency / sequencing graph

```
[ tractusx-identityhub ]               [ bpn-did-resolution-service ]
   3.3.1 PR #258 merge   ──┐                  3.5  ✅ 0.6.0 done
   3.3.2 63-char fix    ──┤
   3.3.3 init-context   ──┤
   3.3.4 chart publish  ──┤
                          │
                          ▼
                 [ tractus-x-umbrella ]
                  3.6.1 feature flag
                  3.6.2 init-context wiring
                  3.6.3 post-install Job
                  3.6.4 adopter profile
                  3.6.5 docs

[ tractusx-edc ]   3.4 #2678   ── parallel, optional, not on critical path
```

## 5. Risk register

| Risk | Mitigation |
|---|---|
| #258 stalls again on the 63-char DNS-label review iteration | Pick up the suggested `printf \| trunc 63 \| trimSuffix "-"` helper change directly; it is mechanical. |
| `initial-participant-context` schema cannot express service entries | Confirm before doing umbrella work; if blocked, contribute the schema extension as part of §3.3.3. Without it, fall back to §3.6.3 doing both DID and credential setup (matches PR #396's posture). |
| #2678 lands before §3.3.3, tempting to use the runtime client | Acceptable as a v2; do not block v1 umbrella delivery on it. Document `identityProvider.type=identityhub-runtime` as a future variant. |
| IH chart 63-char issue silently truncates and overlaps two participants' ConfigMaps | Add a `helm template` lint test in umbrella CI that asserts uniqueness of all rendered ConfigMap `metadata.name` values across two-participant installs. |
| Long release names break BDRS or IssuerService templating | Same lint test should cover `bdrs-server` and `tractusx-issuerservice` chart names. |

## 6. Second-pass deep-dive — gaps surfaced after re-reading the umbrella charts

The first six sections were scoped to the **connector → wallet** path only.
Re-reading [`charts/umbrella/values.yaml`](../../../charts/umbrella/values.yaml),
[`charts/dataspace-connector-bundle/values.yaml`](../../../charts/dataspace-connector-bundle/values.yaml),
[`charts/values-test-data-exchange.yaml`](../../../charts/values-test-data-exchange.yaml),
and [`.github/workflows/helm-checks.yaml`](../../../.github/workflows/helm-checks.yaml)
surfaces a wider impact.

### 6.1 The wallet stub is wired into eight independent code paths, not one

`ssi-dim-wallet-stub` is **not just a connector wallet** — it is a
multi-protocol stub that emulates the **SAP-DIM HTTP surface** for every
service in the umbrella that needs DIM-style integration. Eight distinct
consumers in `charts/umbrella/values.yaml`:

| # | Consumer (umbrella values key) | Endpoint shape it expects | Replaceable by IdentityHub? |
|---|---|---|---|
| 1 | `tractusx-connector.iatp.sts.dim.url` (per participant) | `POST /api/sts` (DIM Secure Token Service) | **No direct equivalent.** IH exposes its own STS at `/api/identity/v1alpha/participants/{ctx}/token` with a different request shape. Needs either a `tx-sts-identityhub` extension (tractusx-edc) **or** verification that the connector accepts IH's STS shape under `iatp.sts.dim.url`. **Open question — see §11.** |
| 2 | `tractusx-connector.iatp.sts.oauth.token_url` | `POST /oauth/token` (OAuth2 client_credentials for DIM) | **Not needed.** IH STS is direct; no OAuth bootstrapping. Block must be omitted in IH mode. |
| 3 | `tractusx-connector.controlplane.env.TX_IAM_IATP_CREDENTIALSERVICE_URL` | DCP CredentialService API (`/api/credentials/v1`) | ✅ Yes — IH **is** a CredentialService. Repoint to `https://{ih-host}/api/credentials/v1/participants/{base64url-did}`. |
| 4 | `tractusx-connector.controlplane.bdrs.server.url` | BDRS `/api/v1/directory` | ✅ Yes — point at `bdrs-server-memory:0.6.0` instead of stub. |
| 5 | `portal.custodianAddress` (legacy MIW client) | MIW REST API | ❌ **No.** IH is not MIW. Must disable Portal "Custodian" client. |
| 6 | `portal.dimWrapper.{baseAddress,tokenAddress,apiPath}` + `portal.backend.processesworker.dim.baseAddress` | SAP-DIM REST API for *creating wallets per BPN* | ❌ **No.** IH does not expose SAP-DIM-shaped wallet provisioning. |
| 7 | `portal.decentralIdentityManagementAuthAddress` | DIM `/api/sts` | ❌ Same as #1, but for Portal not connector. |
| 8 | `ssi-credential-issuer.{walletAddress,walletTokenAddress,credential.statusListUrl}` | DIM-shape wallet + Status List 2021 host | ❌ Different service entirely. Replace with `tractusx-issuerservice` chart (separate Eclipse Tractus-X project), not in scope of "data exchange" wallet swap. |

**Implication.** Items 5–8 belong to the **Portal/onboarding** stack and have
**no IdentityHub equivalent**. Switching the connector wallet from stub to IH
without addressing the Portal stack will leave Portal unable to provision
wallets, list credentials, or issue VCs.

### 6.2 Scope decision: identityhub mode is a **data-exchange-only** profile in v1

The only sustainable v1 scope is to gate the IH switch behind
`identityProvider.type=identityhub` **and** disable the entire Portal /
onboarding / SSI-Credential-Issuer / BPDM-onboarding chain when that mode is
selected. Concretely the IH profile must set:

```yaml
portal:
  enabled: false              # disables custodian, dimWrapper, sts auth, processesworker
ssi-credential-issuer:
  enabled: false              # already default-false today
sdfactory:
  enabled: false              # depends on portal
bpdm:
  enabled: false              # depends on portal client onboarding
centralidp:
  enabled: false              # only needed for portal
sharedidp:
  enabled: false              # only needed for portal
```

This matches the topology of [`Federity-X/public-tractusx-edc/dcp-v2`](https://github.com/Federity-X/public-tractusx-edc/tree/dcp-v2/deployment/local)
(which has no Portal at all) and the topology of AYaoZhan's PR #396 (which
also targets a `identityhub-data-exchange` branch, not the full umbrella).
Treat full Portal+IH integration as a **separate, future workstream**; it
requires Portal-side changes upstream in `eclipse-tractusx/portal-backend`
to consume IH instead of DIM, which is out of scope here.

### 6.3 STS path is the real tractusx-edc gap, not DID registration

§3.4 understated `tractusx-edc#2678`. There are actually **two distinct
sub-concerns** in the connector ↔ IH integration:

| Sub-concern | Today (DIM) | With IH | Workaround for v1? |
|---|---|---|---|
| **Issue SI tokens** (the connector calls a STS to mint a `dataspace-protocol` access token at every contract/transfer step) | `tx-sts-dim-remote` extension calls SAP-DIM `/api/sts` | Needs `tx-sts-identityhub-remote` extension calling IH's `participants/{ctx}/token` endpoint, **or** an in-process `sts-embedded-vault` mode reading a JWK from vault | **In-process embedded STS** (eclipse-edc `sts-server` runtime) is a viable v1 workaround — connector signs SI-tokens locally with a vault-stored JWK. Avoids the IH-STS HTTP gap entirely. |
| **Register/update DID Document service entries** (DSP URL etc.) | `tx-edr-callback` / `DidDocumentServiceClient` (DIM) | Needs `DidDocumentServiceClient` (IH) — `wahidulazam` PR #8 reference impl | **Avoid at runtime**: seed via `initial-participant-context` (§3.3.3). |

So the recommended v1 path is:

1. **STS** → embedded JWK signer (eclipse-edc `sts-embedded`), no
   tractusx-edc change.
2. **DID document** → declarative seed via IH chart, no tractusx-edc change.
3. **CredentialService** → repoint env var, no tractusx-edc change.
4. **BDRS** → repoint env var to real BDRS 0.6.0, no tractusx-edc change.

Verifying that tractusx-connector chart 0.10+ supports `iatp.sts.embedded`
(or equivalent) is the **single most important pre-flight check** for the
whole plan. See §11.

### 6.4 Per-participant duplication lives in *three* blocks, not one

`charts/umbrella/values.yaml` repeats the IATP+STS+BDRS+CredentialService
block in three places:

- `dataconsumerOne` (lines 1086–1110)
- `dataconsumerTwo` (mirror block)
- `tx-data-provider` (lines 1161+)

Plus the same shape repeats in the standalone profile
[`charts/values-test-data-exchange.yaml`](../../../charts/values-test-data-exchange.yaml)
(itself referenced by CI: see §6.6). The §3.6.4 templating refactor must
cover **all four** blocks, not just the two consumers. Option: extract a
single `_iatp.tpl` partial keyed on `participant.bpn` and
`identityProvider.type`.

### 6.5 Vault seeding diverges between modes

The dataspace-connector-bundle today seeds vault with DIM-OAuth secrets
([dataspace-connector-bundle/values.yaml lines 213–222](../../../charts/dataspace-connector-bundle/values.yaml)):

```yaml
vault.server.postStart:
  - sleep 5
  - /bin/vault kv put secret/client-secret content=kEmH7QRPWhKfy8f+x0pFMw==
  - /bin/vault kv put secret/aesKey content=YWVzX2VuY2tleV90ZXN0Cg==
```

For `identityhub` mode the same Vault must instead hold:

| Alias | Purpose | Source |
|---|---|---|
| `tokenSignerPrivateKey` | EC/RSA JWK used by embedded STS to sign SI-tokens | Generated per-participant by post-install Job (or pre-seeded by GitOps) |
| `tokenSignerPublicKey` | Verifier-side JWK (matches `did:web` `verificationMethod`) | Same |
| `identityhub-api-key` (alias) | X-Api-Key for IH Identity Admin API (only if §3.3.3 not used) | Provided by IH chart `apiKey.value` |

The Vault `postStart` block must therefore be conditional:

```yaml
postStart:
  {{- if eq .Values.identityProvider.type "wallet-stub" }}
  - … existing DIM seeds …
  {{- else if eq .Values.identityProvider.type "identityhub" }}
  - … JWK + IH API key seeds …
  {{- end }}
```

Or, more cleanly, generate keys inside the post-install issuance Job (§3.6.3).

### 6.6 CI test profiles are not yet covered by the plan

[`helm-checks.yaml`](../../../.github/workflows/helm-checks.yaml) drives:

- `ct lint` over all charts (passes if Chart.yaml is valid).
- `ct install` of `simple-data-backend` and `tx-data-provider` (single-chart smoke).
- `helm install umbrella -f charts/values-test-data-exchange.yaml` (full
  data-exchange profile against the wallet stub — line 206).
- `helm install umbrella -f charts/values-test-iam-init-container-{1,2}.yaml`
  (IAM init-container smoke — lines 235, 256).
- `helm install umbrella -f charts/values-test-shared-services-{1,2}.yaml`
  (Portal + shared services smoke — lines 279, 301).

To prevent the IH switch from breaking the existing pipeline:

1. **Add** `charts/values-test-data-exchange-identityhub.yaml` — a new
   profile mirroring `values-test-data-exchange.yaml` but with
   `identityProvider.type=identityhub`, `tractusx-identityhub.enabled=true`,
   `tractusx-issuerservice.enabled=true`, all Portal subcharts disabled.
2. **Add a new CI step** in `helm-checks.yaml` that does
   `helm install umbrella -f charts/values-test-data-exchange-identityhub.yaml --wait --wait-for-jobs`
   followed by a smoke probe of one DSP `catalog/request` against the
   provider control-plane (validates the full token issuance + presentation
   + verification path in CI).
3. **Do not modify** the existing data-exchange test profile — it must
   continue to validate the `wallet-stub` legacy path.

### 6.7 did:web hosting and HTTP-vs-HTTPS resolution

`did:web:host:bpn` resolves over HTTPS by default per the DID spec. The
umbrella runs in-cluster with `nginx` ingress and self-signed TLS at best
(`values-tls.yaml`). The connector today uses `EDC_IAM_DID_WEB_USE_HTTPS:
false` to allow HTTP resolution. For IH mode the same flag must be set:

- On the connector control-plane and data-plane envs.
- On the IssuerService (so it can resolve holder DIDs during issuance).
- On the IH (so it can resolve trusted-issuer DIDs during presentation
  verification).

Plus, the IH chart's ingress must serve `/{base64url-did}/did.json` over the
*same* hostname encoded into the DID itself, otherwise `did:web` resolution
404s. PR #396 had this working; copy that ingress shape verbatim.

### 6.8 Trust framework and trusted-issuers list

`iatp.trustedIssuers` in every connector block today contains exactly one
entry: `did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003CRHK`. In IH mode,
this becomes `did:web:{ih-issuer-host}:BPNL00000003CRHK` (or whichever BPN
runs `tractusx-issuerservice`). The IssuerService **must own a stable,
well-known DID** that all participant connectors trust. Adopters who add
their own trust anchor must replace this list, not append to it.

This matters for §3.6.4 adopter profile: trustedIssuers should be **a
top-level list** in the umbrella values, fanned out to all participant
blocks via the templating refactor — not duplicated by hand.

### 6.9 Updated Sprite map of repo work

The §3 table grows by:

| Repo | New / promoted task | Why |
|---|---|---|
| `eclipse-edc/Connector` | (still ❌ no upstream change). But document the embedded-STS path for IH adopters. | §6.3 — embedded STS dodges #2678. |
| `eclipse-tractusx/tractusx-edc` | 🟢 → 🟡 — `tx-sts-dim-remote` config still works for DIM; **no new STS extension required** if embedded STS is acceptable. #2678 (DID-document client) remains optional. | §6.3 |
| `eclipse-tractusx/tractusx-identityhub` | New 3.3.5 — verify chart's ingress serves `did.json` at `/{base64url-did}/did.json` **and** at the friendly path used by `services[].serviceEndpoint`. | §6.7 |
| `eclipse-tractusx/tractus-x-umbrella` | Promoted: 3.6.6 = templated `_iatp.tpl` partial covering `dataconsumerOne`, `dataconsumerTwo`, `tx-data-provider`, plus `values-test-data-exchange*.yaml`. 3.6.7 = conditional Vault `postStart`. 3.6.8 = new CI profile + workflow step. 3.6.9 = scope-decision documentation that IH mode disables Portal stack. | §6.2, §6.4, §6.5, §6.6 |

## 7. Open questions / pre-flight verification

These were posed in v1 of this document. The answers below are based on
reading
[`tractusx-edc/charts/tractusx-connector/values.yaml@main`](https://github.com/eclipse-tractusx/tractusx-edc/blob/main/charts/tractusx-connector/values.yaml)
([commit `63d6e20`](https://github.com/eclipse-tractusx/tractusx-edc/commit/63d6e20e3883d92f2636fb1b02b401791cc8c84d), PR
[#2742](https://github.com/eclipse-tractusx/tractusx-edc/pull/2742)
"Adapt participant id in helm charts"),
[`tractusx-identityhub/extensions@main`](https://github.com/eclipse-tractusx/tractusx-identityhub/tree/main/extensions),
and
[`portal-backend#1422`](https://github.com/eclipse-tractusx/portal-backend/pull/1422).

> ⚠️ **The verification round overturns three earlier assumptions in §6.**
> The corrected guidance is in §10 below; this section preserves the
> evidence chain.

### 7.1 Q1 — Does `tractusx-connector` chart expose embedded STS?

**No.** `main` exposes only one STS configuration block:

```yaml
dcp:
  sts:
    div:
      url:
    oauth:
      token_url:
      client:
        id:
        secret_alias:
```

`div` is the renamed `dim` block (Decentralized Identifier Verifier). There
is **no `dcp.sts.embedded`** key. Embedded STS would still require either
custom `env:` overrides (`EDC_IAM_STS_PRIVATEKEY_ALIAS`, etc., assuming the
upstream EDC `sts-embedded` module is on the classpath of the
tractusx-connector image) or a chart change. **Pre-flight Q1 answer is
negative at the values.yaml level.** Embedded STS as v1 path is **not
free** — it requires either a chart PR exposing those keys or
`controlplane.env` overrides whose support depends on which sts-* modules
the tractusx-connector runtime image bundles.

### 7.2 Q2 — Does the connector accept IH STS shape on `dcp.sts.div.url`?

Almost certainly **no**. The DIV/DIM endpoint at
`/api/sts` accepts a SAP-DIM-shaped `POST` (audience + scope + grant_type
form). IdentityHub's STS surface is `POST /v1alpha/participants/{ctx}/token`
with a different body shape (signed `client_assertion` + `audience` claim).
A direct re-point will fail signature/shape validation. Confirmation
requires either tracing tractusx-edc's `RemoteSecureTokenService`
implementation source or a runtime spike. **Pre-flight Q2 answer is
provisional negative; needs a 30-min code spike against tractusx-edc
`tx-sts-dim-remote` extension.**

### 7.3 Q3 — Does `iatp` → `dcp` rename hit umbrella adopters?

**Yes — this is a breaking change.** Every umbrella consumer of
`tractusx-connector` chart 0.10+ must rename their values keys. The
umbrella's `values.yaml` and `dataspace-connector-bundle/values.yaml`
**still use `iatp.`** ([umbrella values.yaml line 1086](../../../charts/umbrella/values.yaml),
[dataspace-connector-bundle values.yaml lines 30–60](../../../charts/dataspace-connector-bundle/values.yaml)).
A separate **migration task** must be tracked: `iatp` → `dcp`,
`participant.id` (BPN string) → `participant.id` (DID) +
`participant.bpnl` (BPN string) + `participant.contextId` (UUID).
The participant-id semantics change is the riskier part: today the umbrella
sets `participant.id: BPNL00000003AZQP`; the new chart expects
`participant.id: did:web:...`. **This will break PR #396 too.**

### 7.4 Q4 — Does `tractusx-connector` chart expose a DID-Service self-registration toggle?

**Yes — this is new and material.** `main` exposes:

```yaml
dcp:
  didService:
    selfRegistration:
      enabled: false
```

This is the chart-level toggle for the `DidDocumentServiceClient` SPI
([`tractusx-edc#2678`](https://github.com/eclipse-tractusx/tractusx-edc/issues/2678))
that PR #8 in `Federity-X/public-tractusx-edc` provided an IdentityHub
implementation for. The presence of this knob in the chart strongly
suggests the corresponding runtime extension has at least the SPI surface
landed in tractusx-edc `main`. **#2678 is therefore further along than v1
of this document represented.** The IH-implementation merge state still
needs to be checked against tractusx-edc PRs by `wahidulazam` /
`AYaoZhan`. (PR list:
[tractusx-edc/pulls?q=did-document](https://github.com/eclipse-tractusx/tractusx-edc/pulls?q=did-document).)

### 7.5 Q5 — Does the `initial-participant` extension exist in tractusx-identityhub?

**Yes, and it's actively maintained.** Real path:
[`extensions/identityhub/initial-participant`](https://github.com/eclipse-tractusx/tractusx-identityhub/tree/main/extensions/identityhub/initial-participant)
(not `extensions/initial-participant-context` as the v1 doc guessed). Last
touched by **AYaoZhan, 2 months ago**: commit `246fa8a` "refactor: update
values so they are similar to the connector". Same author who runs PR #258
and umbrella PR #396 — meaning a single contributor already owns the
module + its chart wiring + the umbrella consumer side. The `service[]`
schema for DSP/CredentialService entries needs source-level confirmation
(Java DTO + extension config), but the activity pattern means a service-
entry schema PR there would land quickly.

Adjacent finding: a separate
[`extensions/seed/super-user`](https://github.com/eclipse-tractusx/tractusx-identityhub/tree/main/extensions/seed/super-user)
module also exists. The IH already supports declarative bootstrapping of
super-user credentials at install time, lowering the post-install Job
surface area for §3.6.3.

### 7.6 Q6 — Is `bdrs-server-memory` 0.6.0 chart published, and does it expose seeding via values?

Could not fetch the dev chart index in this round (`charts/dev/index.yaml`
returned no parseable content). The 0.6.0 release notes list
`PR #284 (BREAKING) postgres v18 + k8s versions` and
`PR #400 (BREAKING) cloud pirates helm chart` — the second is a chart
restructure and may have shifted the `initialMappings` shape. Verify with:

```bash
helm repo update
helm show values tractusx/bdrs-server-memory --version 0.6.0 | grep -A20 'mapping\|seed\|initial'
```

before committing to a values-based seeding strategy. If chart-time
seeding is gone, fall back to a post-install Job calling the BDRS
management API (auth via `bdrs.authKey`).

### 7.7 Q7 (NEW) — Does Portal already support BYOW?

**Yes — this rewrites the scope decision in §6.2.** PR
[`portal-backend#1422`](https://github.com/eclipse-tractusx/portal-backend/pull/1422)
"feat: bring your own wallet" by `leandro-cavalcante` (Cofinity-X),
**merged on Jan 7 2026** into `main`, milestone `26.03`, closes
[`sig-release#1160`](https://github.com/eclipse-tractusx/sig-release/issues/1160)
"Implementation of Onboarding Process and DCP Issuance Flow for BYOW".
The PR adds:

- `BringYourOwnWalletBusinessLogic` + `BringYourOwnWalletController` in
  the Registration Service.
- BYOW flow steps in administration + processes-worker.
- Companion frontend PR
  [`portal-frontend-registration#407`](https://github.com/eclipse-tractusx/portal-frontend-registration/pull/407)
  ("feat: add BYOW step in flow", open).

Additionally, the umbrella's
[`values.yaml` line 109](../../../charts/umbrella/values.yaml)
already has a `portal.backend.useDimWallet: true` flag — i.e. the
upstream Portal already accepts a `useDimWallet: false` mode that
disables the DIM-OAuth path and lets the participant present an
externally-owned wallet (such as IdentityHub-backed) at onboarding time.

**Net effect on the plan**: Portal **does not** need to be disabled in IH
mode. Section 6.2's "data-exchange-only profile" is more conservative
than necessary; v1 can ship with Portal enabled, BYOW set, and IH-backed
participants onboarded through the Portal flow — provided Portal 26.03
chart is released and adopted in the umbrella.

## 8. Bottom line

- **No upstream Eclipse EDC change is needed.**
- **The Portal/onboarding stack is out of scope for v1.** IdentityHub mode
  is a *data-exchange-only* profile; it disables `portal`, `centralidp`,
  `sharedidp`, `bpdm`, `sdfactory`, `ssi-credential-issuer`. Full
  Portal+IH integration requires Portal-backend changes upstream and is a
  separate workstream.
- **The connector-side gap is STS, not DID registration.** Use eclipse-edc
  *embedded* STS (vault-stored JWK) and dodge `tractusx-edc#2678` for v1.
  Confirm via §7 question 1.
- **The actual gating items in `tractusx-identityhub`** are PR #258 +
  `initial-participant-context` services-schema (§3.3.3) + chart
  publication (§3.3.4).
- **BDRS 0.6.0 is already done** — replace the `0.7.0-SNAPSHOT` workaround
  used by PR #396.
- **Umbrella work is now ~9 deliverables** (§3.6.1–§3.6.9), not 5: add the
  `_iatp.tpl` partial, the conditional Vault seed, the new CI profile +
  workflow step, and the scope-decision doc.
- **`tractusx-edc#2678` remains optional** but `wahidulazam`'s PR #8 is
  still valuable as v2 (runtime DID-Document mutation for non-GitOps
  adopters).

## 9. Verification-round corrections to §6

The deep-dive in §6 was written before §7 was answered. The corrections:

| §6 claim | Verified status | Corrected guidance |
|---|---|---|
| §6.2 "Portal must be disabled in IH mode" | **Wrong.** [`portal-backend#1422`](https://github.com/eclipse-tractusx/portal-backend/pull/1422) BYOW merged on Jan 7 2026 (milestone 26.03). Frontend [#407](https://github.com/eclipse-tractusx/portal-frontend-registration/pull/407) follows. | Portal *can* run with IH. v1 should pin Portal chart ≥ 26.03, set `portal.backend.useDimWallet: false`, and route BYOW onboarding to the participant's IH. **§6.2 v1 fallback (Portal disabled) is now optional, not required.** |
| §6.3 "embedded STS dodges #2678" | **Half-right.** Embedded STS is a real eclipse-edc capability, but `tractusx-connector` chart `main` does **not** expose `dcp.sts.embedded` keys; only `dcp.sts.div`. Embedded STS in v1 needs either a chart PR upstream or `controlplane.env` overrides whose runtime support is unverified. | Either (a) upstream a `dcp.sts.embedded` block in tractusx-connector chart, or (b) **commit to #2678 as the v1 path** — which is now reasonable because… |
| §3.4 "#2678 is optional / parallel track" | **Understated.** `tractusx-connector` chart `main` already exposes `dcp.didService.selfRegistration.enabled` (added by [PR #2742](https://github.com/eclipse-tractusx/tractusx-edc/pull/2742), Dec 2025). The SPI surface and chart toggle are landed; only the IH client implementation merge state needs confirmation. | Promote #2678 to **on the critical path**. Verify `wahidulazam`'s PR is rebased on top of `2742` and then drive it to merge. |
| §6.4 "duplication is in 3 blocks" | Confirmed plus one. The `iatp` → `dcp` rename ([§7.3](#73-q3--does-iatp--dcp-rename-hit-umbrella-adopters)) means **all four blocks must also be migrated** to the new schema, not just templated. | Add a **schema-migration sub-task (§3.6.10)**: rename `iatp` → `dcp`, split `participant.id` into `participant.{id,bpnl,contextId}` across `dataconsumerOne`, `dataconsumerTwo`, `tx-data-provider`, `dataspace-connector-bundle/values.yaml`, and `values-test-data-exchange.yaml`. Bump tractusx-connector dependency simultaneously. |
| §3.3.3 "module path is `initial-participant-context`" | **Wrong path.** Real path: [`extensions/identityhub/initial-participant`](https://github.com/eclipse-tractusx/tractusx-identityhub/tree/main/extensions/identityhub/initial-participant). Last commit by AYaoZhan 2 months ago. | Update §3.3.3 to track the actual module. Service-entry schema check is still needed but trivial given AYaoZhan's authorship overlaps with PR #258 + umbrella PR #396. |
| §3.3 missing item | New: [`extensions/seed/super-user`](https://github.com/eclipse-tractusx/tractusx-identityhub/tree/main/extensions/seed/super-user) module exists in IH and seeds the super-user credential at install time. | Reference this in §3.6.3: it removes the need for the post-install Job to do super-user bootstrapping; the Job only needs to handle per-participant credential issuance. |

### 9.1 Revised critical-path graph

```
[ tractusx-edc ]                         [ portal-backend ]
   2742 (chart toggle)        ✅ merged       1422 BYOW          ✅ merged Jan 7
   #2678 IH DidDoc client     🟡 needs verify  → portal chart     🟡 26.03 release
                                              → portal-iam       🟡 26.03 release
        │                                            │
        ▼                                            ▼
[ tractusx-identityhub ]                  [ bpn-did-resolution-service ]
   PR #258 templated CMs    🟡 in review        v0.6.0           ✅ released
   initial-participant      🟢 module exists,
       services schema         needs confirm
   chart publish v0.2.1     🟡 after #258
        │
        ▼
[ tractus-x-umbrella ]
   - dcp schema migration   🔴 §3.6.10 (NEW)
   - feature flag            🔴 §3.6.1
   - subchart deps            🔴 §3.6.1
   - _dcp.tpl partial        🔴 §3.6.6
   - vault postStart cond.   🔴 §3.6.7
   - CI profile + step       🔴 §3.6.8
   - adopter profile         🔴 §3.6.4
   - post-install Job        🔴 §3.6.3 (slimmer thanks to seed/super-user)
   - docs                    🔴 §3.6.5
   - Portal chart bump 26.03 🔴 §3.6.11 (NEW)
```

## 10. Bottom line (revised after verification)

- **No upstream Eclipse EDC change is needed.** Confirmed.
- **BDRS 0.6.0 is released.** Confirmed; plain dependency bump.
- **Portal can stay enabled in IH mode** (`portal-backend#1422` merged
  Jan 7 2026, milestone 26.03). BYOW is the upstream-blessed path. The
  §6.2 "disable Portal" stance is downgraded to *optional escape hatch*
  for adopters who want the smaller stack.
- **`tractusx-edc#2678` is on the critical path, not parallel.** The
  chart toggle (`dcp.didService.selfRegistration.enabled`) is **already
  in `main`** since PR #2742 (Dec 2025), so the SPI is shaped and the
  IH-side implementation by `wahidulazam` is the only remaining piece.
  Drive that to merge; do not plan around dodging it.
- **The `iatp` → `dcp` rename is a breaking schema migration the
  umbrella has not yet absorbed.** A dedicated §3.6.10 sub-task tracks
  it. Without this migration, simply bumping `tractusx-connector` chart
  version will fail.
- **The `tractusx-identityhub initial-participant` module is real and
  active** (commit `246fa8a` by `AYaoZhan` 2 months ago). The plan's
  service-entry-schema dependency is feasible.
- **A `seed/super-user` extension** in IH means the post-install
  issuance Job in §3.6.3 only needs to handle per-participant credential
  issuance, not super-user bootstrap. Slimmer Job.
- **`AYaoZhan` is the connecting contributor across three repos.**
  PR #258 (tractusx-identityhub), the `initial-participant` refactor,
  and umbrella PR #396 are all by the same author. Coordinating with
  them will surface the cleanest end-to-end path; treat their branches
  as the de-facto integration reference together with `wahidulazam`'s
  Federity-X dcp-v2 work.
- **Net work added by the verification round**:
  §3.6.10 (dcp schema migration), §3.6.11 (Portal 26.03 chart bump
  with `useDimWallet: false`), and a 30-min code spike on `tractusx-edc`
  STS shapes to confirm whether embedded STS is a viable alternative or
  whether #2678 is strictly required.


## 11. Verification sweep 3 — concrete artefact reads

This sweep read the actual `values.yaml` and source layouts of the four
repositories to settle items still marked 🟡 in §9.1.

### 11.1 `tractusx-identityhub` chart values shape (read from `main`)

[`charts/tractusx-identityhub/values.yaml`](https://github.com/eclipse-tractusx/tractusx-identityhub/blob/main/charts/tractusx-identityhub/values.yaml)
exposes the following endpoints on the IH pod:

| Endpoint | Port | Path | Auth |
|---|---|---|---|
| `default` (health) | 8081 | `/api` | none |
| `identity` (Admin API) | 8082 | `/api/identity` | `X-Api-Key` (alias `sup3r$3cr3t`) |
| `credentials` (DCP Presentation) | 8083 | `/api/credentials` | DCP token |
| `did` (DID resolution) | 8084 | `/` | none |
| `accounts` (STS accounts admin) | 8085 | `/api/accounts` | `X-Api-Key` |
| `version` (well-known) | 8086 | `/.well-known/api` | none |
| `sts` (STS token issuance) | 8087 | `/api/sts` | per-token |

**Implication for §6.3 / §10**: IdentityHub **does** ship its own STS
endpoint at `:8087/api/sts`. This means the connector chart's
`dcp.sts.div.url` *could* in principle be pointed at IH's STS, sidestepping
the embedded-STS chart-PR question entirely — **provided the request shape
is compatible**. The DIM/DIV STS expects an OAuth2-style token request;
IH's STS is the eclipse-edc `RemoteSecureTokenService` shape (signed
client_assertion). They are **not** compatible without an adapter, so this
remains a 30-min code spike, but it removes "embedded STS chart PR"
from the critical path: the alternative is now "either (a) eclipse-edc
embedded STS via env override, or (b) IH STS at 8087 with shape
verification".

### 11.2 `initial-participant` module values shape

The IH chart exposes initial-participant configuration under an `iatp:`
key (yes, the IH chart kept the old name even after the connector renamed
it to `dcp:` — minor inconsistency to track):

```yaml
iatp:
  sts:
    oauth:
      client:
        enabled: false
        id: "did:web:identityhub.presentation.local"
        secret: "testme"
        secret_alias: "sts-secret"
        x_api_key: "ZGlkOndlYjppZGVudGl0eWh1Yi5wcmVzZW50YXRpb24ubG9jYWw=.randomChars"
```

This is **only** the initial participant's OAuth2 client + super-user
X-Api-Key. **There is no `services[]` array in this schema today.** The
`extensions/identityhub/initial-participant` module currently seeds
*identity*, not *services* (DSP, CredentialService, etc.). Consequence:

- Earlier plan ([§3.3.3](#section-33)) assumed service-entry seeding
  could be added by chart values + a small extension change. The
  module exists, but the schema would have to be **extended** with a
  `services:` list. This is a real upstream PR to
  `tractusx-identityhub`, not a trivial values change.
- Until that PR lands, **the post-install Job in §3.6.3 must** call the
  IH `:8082/api/identity` admin API with `X-Api-Key` to register
  `services[]` per participant. This is the same shape used by
  `wahidulazam`'s `DidDocumentServiceIdentityHubClient` in
  [Federity-X/public-tractusx-edc#8](https://github.com/Federity-X/public-tractusx-edc/pull/8)
  (`POST /v1/unstable/participants/{contextId}/dids/{base64url-did}/endpoints?autoPublish=true`).

### 11.3 `tractusx-edc#2678` status — definitive read

[`tractusx-edc#2678`](https://github.com/eclipse-tractusx/tractusx-edc/issues/2678):

- Issue **open** since Mar 14 2026, last activity ~1 week ago
  (un-staled by `lgblaumeiser`).
- A search for `is:pr author:wahidulazam` in tractusx-edc returns
  **zero results**. The implementation lives entirely in
  [`Federity-X/public-tractusx-edc#7`](https://github.com/Federity-X/public-tractusx-edc/pull/7)
  → superseded by
  [`#8`](https://github.com/Federity-X/public-tractusx-edc/pull/8)
  → superseded again on `dcp-v2` branch (per
  [`c06536d`](https://github.com/Federity-X/public-tractusx-edc/commit/c06536d2d2d03d9b6024d66387229d9ee952d48b)
  Apr 4 "mark dcp branch as stale, redirect to dcp-v2").
- `lgblaumeiser` on Mar 16: *"one of the upcoming topics is to move
  upstream to 0.16.0. So please do not implement anything that has to
  be solved differently with 0.16.0."* → #2678 is **explicitly blocked**
  on the IH 0.16.0 bump in `tractusx-edc`, tracked under
  [`sig-release#1609`](https://github.com/eclipse-tractusx/sig-release/issues/1609)
  (R26.06).
- `wahidulazam`'s PR #8 introduces a breaking change:
  `tx.edc.did.service.client.type=dim|identityhub` selector with
  required explicit value (no implicit activation). DIM deployments
  must add `TX_EDC_DID_SERVICE_CLIENT_TYPE=dim`.

**Implication**: §10's claim that "#2678 is on the critical path; drive
it to merge" was overstated. The realistic timing is **R26.06**
(`sig-release#1609`), gated by tractusx-edc consuming IH 0.16.0
upstream. The umbrella v1 plan must therefore **commit to a non-#2678
path**: either chart-time seeding via the (yet to be enhanced)
`initial-participant` module, or post-install Job hitting IH
`/api/identity`. **#2678 becomes a v2 / R26.06 swap-in.**

### 11.4 BDRS chart — no values-based seeding

Both
[`bdrs-server`](https://github.com/eclipse-tractusx/bpn-did-resolution-service/blob/main/charts/bdrs-server/values.yaml)
and
[`bdrs-server-memory`](https://github.com/eclipse-tractusx/bpn-did-resolution-service/blob/main/charts/bdrs-server-memory/values.yaml)
expose only:

- standard server / pod plumbing
- `endpoints.management` on `:8081 /api/management` with
  `authKeyAlias: "mgmt-api-key"` (real chart) or `authKey: "password"`
  (memory chart, no vault dependency)
- `endpoints.directory` on `:8082 /api/directory`
- `trustedIssuers: []`

There is **no `initialMappings`, no `seed`, no `bootstrap` block**.
BPN→DID seeding **must** be done via the management API after install.
This confirms §3.6.3 needs the post-install Job to:

1. POST `bpn-did` mappings to `bdrs-server-memory:8081/api/management/bpn-directory/`.
2. POST `services[]` entries to each IH `:8082/api/identity/v1/unstable/participants/{ctx}/...`.
3. (Optional, blocked on schema extension) submit any super-user-managed
   credentials via IH credentials admin.

The BDRS-memory variant accepting `authKey: "password"` (vs
`authKeyAlias`) means the umbrella seeding Job does **not** need a vault
secret for BDRS in the dev profile.

### 11.5 IH chart inconsistency — `iatp:` vs connector `dcp:`

The connector chart was renamed `iatp` → `dcp` by
[`tractusx-edc#2742`](https://github.com/eclipse-tractusx/tractusx-edc/pull/2742)
(Dec 2025). The IH chart `main` still uses `iatp:` for its initial
participant block ([`charts/tractusx-identityhub/values.yaml`](https://github.com/eclipse-tractusx/tractusx-identityhub/blob/main/charts/tractusx-identityhub/values.yaml)).
AYaoZhan's commit `246fa8a` "refactor: update values so they are similar
to the connector" was **only** for the extension module, not for this
top-level key. A follow-up rename in IH is likely; track it but treat the
current `iatp:` key as authoritative for v1.

### 11.6 `useSVE` flag observed

IH chart `identityhub.useSVE: false`. SVE = Selective Verifiable
Encryption (eclipse-edc privacy primitive). Default-off. No action
needed; flag for awareness when documenting adopter knobs.

## 12. Final consolidated bottom line

After three verification sweeps:

1. **No upstream Eclipse EDC change is needed.** ✅ Confirmed.
2. **BDRS 0.6.0 is released; values do not seed.** Job-driven seeding
   stays in §3.6.3, hitting `:8081/api/management`.
3. **Portal can run with IH** (BYOW PR #1422 merged Jan 7 2026). v1
   *may* enable Portal with `useDimWallet: false` when the Portal 26.03
   chart releases; until then, ship Portal-disabled and document the
   upgrade path.
4. **`tractusx-edc#2678` is blocked on IH 0.16.0 upstream bump** in
   tractusx-edc (sig-release #1609, R26.06). It is **not** on the v1
   critical path. Plan around it; treat `wahidulazam`'s PR #8 as the
   R26.06 reference, not a v1 dependency.
5. **The `dcp.didService.selfRegistration.enabled` chart toggle exists**
   but its IH-client implementation is not in tractusx-edc `main`.
   Setting it `true` in v1 is a no-op without #2678. **Leave it `false`
   in v1.**
6. **The `iatp` → `dcp` schema rename in `tractusx-connector`** is a
   real breaking migration the umbrella has not absorbed (§3.6.10).
7. **The `initial-participant` IH module today seeds only identity, not
   services.** v1 service-entry seeding **must** go through the
   post-install Job hitting IH `:8082/api/identity`. A schema-extension
   PR to `tractusx-identityhub` is queued for v2.
8. **IH ships its own `:8087/api/sts` endpoint.** Whether the connector
   can re-use it via `dcp.sts.div.url` (instead of embedded STS or DIM)
   is a 30-min code spike on request-shape compatibility. If yes, it
   eliminates the §6.3 ambiguity entirely.
9. **AYaoZhan + wahidulazam own the de-facto reference implementations**
   across `tractusx-identityhub` (PR #258 + `initial-participant`
   refactor + umbrella PR #396) and `tractusx-edc` (Federity-X dcp-v2,
   #2678). Coordinate with both.
10. **CI** in the umbrella (`.github/workflows/helm-checks.yaml`) will
    need a fourth profile (`identityhub`) added to the `helm install`
    matrix, plus a `ct lint`/`ct install` pass for the new
    `identity-and-trust-bundle` IH dependency. (§3.6.8)

### 12.1 v1-scoped, verifiable umbrella deliverables

- **§3.6.1** Add `tractusx-identityhub` (+`-memory` variant) as conditional
  dependency in `identity-and-trust-bundle/Chart.yaml`. Feature flag:
  `identityHub.enabled: false` (default).
- **§3.6.3** Post-install Job:
  - BDRS BPN→DID mapping POST.
  - IH service-entry POST per participant
    (`/v1/unstable/participants/{contextId}/dids/.../endpoints`).
  - Optional super-user credential issuance (`seed/super-user` already
    handles bootstrap inside IH at install time).
- **§3.6.4** New adopter profile values file
  `values-adopter-data-exchange-identityhub.yaml`.
- **§3.6.6** `_dcp.tpl` partial replacing per-connector `iatp:`/`dcp:`
  block duplication across `dataconsumerOne`, `dataconsumerTwo`,
  `tx-data-provider`.
- **§3.6.7** Conditional Vault `postStart` seed: stub-mode keys vs IH
  `client-secret` + `aesKey` aliases.
- **§3.6.8** CI: add `identityhub` profile to helm-checks workflow.
- **§3.6.10** Migrate **all** umbrella `iatp:` references to `dcp:`,
  split `participant.id` into `{id, bpnl, contextId}`, when bumping
  `tractusx-connector` chart. Independent of IdentityHub work; required
  before any chart bump.
- **§3.6.11** (deferred) Portal 26.03 chart bump with
  `useDimWallet: false`. Out of v1 unless Portal 26.03 chart is
  published before umbrella v1 cut-off.

### 12.2 Outstanding verification items (none blocking v1 plan)

- [ ] 30-min code spike: does eclipse-edc `RemoteSecureTokenService`
      accept IH `:8087/api/sts` shape? If yes, simplifies §6.3.
- [ ] `helm search repo tractusx/tractusx-identityhub-memory` — confirm
      0.2.x chart is published to `charts/dev`.
- [ ] Track tractusx-identityhub schema-extension PR for `services[]`
      in `extensions/identityhub/initial-participant`. File the PR if
      no one else has by the time §3.6.3 lands.

This plan is now on solid ground: the v1 architecture, the work split,
and the deferred items are all backed by direct reads of the current
`main` branches of the relevant repos.
