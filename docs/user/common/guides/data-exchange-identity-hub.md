# Data Exchange with Real IdentityHub (identityHub wallet mode)

This guide shows how to deploy the umbrella data-exchange subset against a
real [tractusx-identityhub](https://github.com/eclipse-tractusx/tractusx-identityhub)
+ IssuerService pair instead of the default
[ssi-dim-wallet-stub](https://github.com/eclipse-tractusx/ssi-dim-wallet-stub).

> **Status (26.06 milestone):** work-in-progress, tracked under
> [eclipse-tractusx/sig-release#1609](https://github.com/eclipse-tractusx/sig-release/issues/1609).
> The shared-IH topology is the target for 26.06; per-participant topology is
> deferred to 26.09.

## Overview

The umbrella chart exposes a single toggle — `wallet.mode` — that selects the
wallet implementation for the entire data-exchange subset:

| `wallet.mode`  | Wallet chart used                                                            | Status       |
| -------------- | ---------------------------------------------------------------------------- | ------------ |
| `stub`         | `ssi-dim-wallet-stub` (current default, no DCP seeding required)             | stable       |
| `identityHub`  | `tractusx-identityhub-memory` + `tractusx-issuerservice-memory` (in-memory)  | **26.06 WIP**|

When `wallet.mode=identityHub` is selected, umbrella:

1. renders a single `<release>-wallet-mode` ConfigMap containing the full list
   of participants (`operator`, `provider`, `consumer1`, `consumer2`), their
   derived DIDs, IdentityHub credential-service URLs, and the issuer DID;
2. runs a post-install Job (`<release>-dataprovider-post-install-identityhub-seed`)
   that executes the complete
   [DCP API walkthrough](https://github.com/eclipse-tractusx/tractusx-identityhub/tree/main/docs/usage/dcp-api-walkthrough)
   (10 steps, idempotent) against IH / IS, seeding every participant with
   Membership / DataExchangeGovernance / FrameworkAgreement credentials.

## Prerequisites

Same as the default stub-mode guide:

- a running Kubernetes cluster (minikube, kind, k3s, or similar)
- `kubectl`, `helm` 3.12+
- `/etc/hosts` entries for `*.tx.test` (see
  [Cluster Setup](../setup/cluster/README.md))

Two additional hostnames are required in `identityHub` mode:

```hosts
127.0.0.1  identity-hub.tx.test
127.0.0.1  issuer-service.tx.test
```

## Single-command deploy

```bash
helm repo add tractusx-dev https://eclipse-tractusx.github.io/charts/dev
helm dependency build charts/umbrella

helm install umbrella charts/umbrella \
  --namespace umbrella --create-namespace \
  -f charts/values-test-data-exchange-identity-hub.yaml
```

The profile file
[`values-test-data-exchange-identity-hub.yaml`](../../../../charts/values-test-data-exchange-identity-hub.yaml)
performs three things:

1. sets `wallet.mode: identityHub` at the umbrella level;
2. disables `ssi-dim-wallet-stub` and enables `tractusx-identityhub-memory`
   + `tractusx-issuerservice-memory` inside `identity-and-trust-bundle`;
3. flips `tx-data-provider*.wallet.mode` to `identityHub` so the seeding Job
   runs once per tx-data-provider release (idempotent — later runs observe
   HTTP 409 on already-created participants and pass through).

## Verifying the seed

Once `helm install` returns, the seeding Job prints a summary line:

```bash
kubectl -n umbrella logs job/umbrella-dataprovider-post-install-identityhub-seed \
  | grep SEED\ SUMMARY
# [ih-seed]  SEED SUMMARY: 4 participants seeded successfully
```

You can also introspect IdentityHub directly (the super-user API key is
printed once in the IH pod log at startup):

```bash
IH_POD=$(kubectl -n umbrella get pod \
  -l app.kubernetes.io/name=tractusx-identityhub-memory \
  -o jsonpath='{.items[0].metadata.name}')
IH_KEY=$(kubectl -n umbrella logs "$IH_POD" \
  | grep -oE "API Key for '[^']*': *[A-Za-z0-9_.-]+" | head -n1 \
  | sed -E "s/.*: *//")

curl -sS -H "x-api-key: $IH_KEY" http://identity-hub.tx.test/api/identity/v1alpha/participants \
  | jq '.[].participantId'
# "operator-bpnl00000003crhk"
# "provider-bpnl00000003ayre"
# "consumer-bpnl00000003azqp"
# "consumer-bpnl00000003avth"
```

## Troubleshooting

**The helm install fails with "execution error … only one of `ssi-dim-wallet-stub.enabled` or `identity-hub.enabled` may be true at a time".**

The umbrella chart includes a mutual-exclusion validator
(`charts/umbrella/templates/_wallet-validate.tpl`). Either stick to the
shipped profile file or make sure exactly one of the two is enabled under
`identity-and-trust-bundle`.

**The seed Job times out on `kubectl wait --for=condition=Ready pod …`.**

The in-memory IH / IS pods can take ~60–90 s to finish their first boot.
Increase the timeout:

```bash
helm upgrade umbrella charts/umbrella \
  -f charts/values-test-data-exchange-identity-hub.yaml \
  --set tx-data-provider.wallet.identityHubSeed.readinessTimeoutSeconds=600
```

**Credential request stays in `PENDING` forever.**

This is the **expected current state** on a vanilla cluster — see
*Known limitations* below. The seed Job emits a clear `WARN` line per
credential type and continues; provisioning still completes.

## Verification

After `helm install` finishes, the post-install seed Job runs once.
Confirm the SEED SUMMARY:

```bash
kubectl -n umbrella logs job/<release>-tx-data-provider-post-install-identityhub-seed --tail=20
```

You should see:

```
[ih-seed] ================================================================
[ih-seed]  SEED SUMMARY: 4 participants provisioned successfully
[ih-seed]  (issuer=issuer-bpnl00000003crhk activated, all holders created+activated+registered)
[ih-seed]  credentialDefinitions configured: DataExchangeGovernanceCredential,FrameworkAgreementCredential,MembershipCredential
[ih-seed]  Credential issuance (§8/§9) is best-effort; check WARN lines
[ih-seed]  above to assess DCP exchange readiness on this cluster.
[ih-seed] ================================================================
```

Pod-level health:

```bash
kubectl -n umbrella get pods -l app.kubernetes.io/name=identity-hub
kubectl -n umbrella get pods -l app.kubernetes.io/name=issuer-service
```

Both should be `1/1 Running`. The seed Job pod should be `0/1 Completed`.

## Known limitations

| ID  | Limitation                                                                                                  | Workaround                                                                                                                              |
|-----|-------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------|
| L1  | `tractusx-issuerservice-memory:0.2.0` does **not** bundle the `issuance-database-attestation` extension.    | §5/§6/§9 of the seed Job report `WARN` and VC issuance is not available end-to-end. Use a custom IS image with the extension to enable. |
| L2  | `tractusx-connector:0.11.2` schema still uses `iatp.sts.dim.url` instead of first-class `dcp.*` keys.       | The profile carries the legacy keys; will be cleaned up when the connector chart >= 0.13 is consumed.                                  |
| L3  | All holders share a single Identity Hub host (`identity-hub.tx.test`).                                      | Use the `-per-participant` sibling profile (planned 26.09) for one IH per BPN.                                                          |

See [`docs/common/concept/1609-local-test-findings.md`](../../../common/concept/1609-local-test-findings.md)
for the full Phase 9 + Phase 10 retrospective with reproducible commands.

## Teardown

```bash
helm uninstall umbrella -n umbrella
kubectl delete ns umbrella
```

## What's next

- **26.06:** harden the shared-IH topology + publish ready-to-use
  [Bruno collection](../../../common/api/README.md) for DCP smoke tests.
- **26.09:** activate the per-participant topology (one IH per BPN) via the
  `values-test-data-exchange-identity-hub-per-participant.yaml` profile.

## NOTICE

This work is licensed under the
[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/legalcode).
