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

## 6. Bottom line

- **No upstream Eclipse EDC change is needed.**
- **No tractusx-edc change is required for the umbrella critical path.** The
  full integration can ship by leaning on IH-side
  `initial-participant-context` seeding (§3.3.3), which the existing PR #396
  did not exploit.
- The actual gating items are **`tractusx-identityhub` PR #258 + chart
  publication + `initial-participant-context` services schema**.
- BDRS 0.6.0 is already done.
- Umbrella work is then ~5 deliverables in `identity-and-trust-bundle`,
  `tx-data-provider`, and `umbrella` charts plus one adopter profile.
- `tractusx-edc#2678` remains valuable as a parallel track for runtime
  DSP-URL changes (non-GitOps adopters), but it is **not** what unlocks
  IdentityHub-based data exchange in the umbrella.
