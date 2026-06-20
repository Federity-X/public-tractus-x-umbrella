# Data Exchange with Real IdentityHub (identityHub wallet mode)

This guide shows how to deploy the umbrella data-exchange subset against a
real [tractusx-identityhub](https://github.com/eclipse-tractusx/tractusx-identityhub)
+ IssuerService pair instead of the default
[ssi-dim-wallet-stub](https://github.com/eclipse-tractusx/ssi-dim-wallet-stub),
and run a **full DCP data exchange** (catalog → contract negotiation → transfer
→ fetch) end-to-end.

> **Status (26.06 milestone):** tracked under
> [eclipse-tractusx/sig-release#1609](https://github.com/eclipse-tractusx/sig-release/issues/1609).
> The full DCP data-transfer flow has been validated end-to-end on all three
> IdentityHub profiles below (shared, per-participant, and persistent/postgres).
> See **[Version requirement](#version-requirement)** — the working flow needs
> the EDC-0.17.0-aligned components; until they are released the local-image
> overlay is required.

## Overview

The umbrella chart exposes a single toggle — `wallet.mode` — that selects the
wallet implementation for the entire data-exchange subset. Within
`identityHub` mode there are three mutually-exclusive Holder-Wallet variants
(enforced by `charts/umbrella/templates/_wallet-validate.tpl`):

| Profile (`-f charts/…`)                                     | Wallet chart                                  | Topology / store                                  |
| ----------------------------------------------------------- | --------------------------------------------- | ------------------------------------------------- |
| `values-test-data-exchange.yaml` (default)                  | `ssi-dim-wallet-stub`                         | stub, no DCP seeding                              |
| `values-test-data-exchange-identity-hub.yaml`               | `tractusx-identityhub-memory` (`identity-hub`)| **shared** in-memory IH (one multi-tenant host)   |
| `values-test-data-exchange-identity-hub-per-participant.yaml`| `tractusx-identityhub-memory` ×4              | **per-participant** — one in-memory IH per BPN    |
| `values-test-data-exchange-identity-hub-postgres.yaml`      | `tractusx-identityhub` (`identity-hub-postgres`)| **persistent** IH backed by PostgreSQL          |

All three identityHub profiles share one IssuerService (`tractusx-issuerservice`,
postgres variant — its bundled `database` attestation is required by the DCP
issuance walkthrough). When an identityHub profile is selected, umbrella:

1. renders a `<release>-wallet-mode` ConfigMap with the participant set
   (`operator`, `provider`, `consumer1`, `consumer2`), their derived DIDs,
   IdentityHub credential-service URLs, and the issuer DID;
2. runs a post-install seeding Job that executes the
   [DCP API walkthrough](https://github.com/eclipse-tractusx/tractusx-identityhub/tree/main/docs/usage/dcp-api-walkthrough)
   against IH / IS — creating every ParticipantContext and issuing each holder a
   MembershipCredential, BpnCredential, DataExchangeGovernanceCredential and
   FrameworkAgreementCredential;
3. seeds the BDRS directory (`post-install-bdrs-setup`) with each participant's
   `did:web → BPN` mapping (required for the transfer-layer BPN resolution).

## Version requirement

The full DCP exchange requires the **EDC 0.17.0-aligned** stack:

| Component                | Needed                     | Reason                                                                                             |
| ------------------------ | -------------------------- | -------------------------------------------------------------------------------------------------- |
| `tractusx-connector`     | `0.13.0` (EDC 0.17.0)      | catalog-time credential presentation; EDC 0.17.0 uses the **plain** `participantContextId` in URLs |
| IdentityHub / IssuerService | `0.17.0`                | matching plain-`participantContextId` credential-service routing (IH #937)                         |

At the time of writing those are not yet on a public release channel, so they
are **built from source** and the bundle `Chart.yaml`s still pin the 0.16.0 line
(`tractusx-connector:0.13.0-rc2`, IH/IS `v0.3.2`):

- the connector control/data-plane images are built from [`tractusx-edc` **main**](https://github.com/eclipse-tractusx/tractusx-edc) (EDC 0.17.0, tagged `0.13.0-SNAPSHOT`);
- the IdentityHub + IssuerService images are built from [tractusx-identityhub **PR #309**](https://github.com/eclipse-tractusx/tractusx-identityhub/pull/309) (the EDC 0.17.0 upgrade).

To run the validated flow today, layer the local-image overlay
[`values-test-data-exchange-identity-hub-local-0.17.0.yaml`](../../../../charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml),
which pins those images. They must be **pre-loaded into the cluster** (not on a
public registry) — e.g. for kind:

```bash
kind load docker-image \
  docker-identityhub-memory:latest \
  docker-identityhub:latest \
  docker-issuerservice:latest \
  tractusx/edc-controlplane-postgresql-hashicorp-vault:0.13.0-SNAPSHOT \
  tractusx/edc-dataplane-hashicorp-vault:0.13.0-SNAPSHOT \
  --name <cluster>
```

Once `tractusx-connector 0.13.0` and IdentityHub/IssuerService 0.17.0 are
released, bump the bundle `Chart.yaml` pins and drop the overlay.

## Prerequisites

- a running Kubernetes cluster (kind, minikube, k3s, …)
- `kubectl`, `helm` 3.12+, plus `curl` + `jq` for the smoke test
- `/etc/hosts` entries for `*.tx.test` (see [Cluster Setup](../setup/cluster/README.md));
  in identityHub mode you additionally need:

```hosts
127.0.0.1  identity-hub.tx.test
127.0.0.1  identity-hub-admin.tx.test
127.0.0.1  issuer-service.tx.test
```

(The per-participant profile also needs `ih-operator|provider|consumer1|consumer2.tx.test`.)

## Single-command deploy

Pick one profile. Shared in-memory IH (the lightest):

```bash
helm repo add tractusx-dev https://eclipse-tractusx.github.io/charts/dev
helm dependency build charts/umbrella

helm install umbrella charts/umbrella \
  --namespace umbrella --create-namespace --timeout 25m \
  -f charts/values-test-data-exchange-identity-hub.yaml \
  -f charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml
```

Swap the first `-f` for `…-per-participant.yaml` (4 IdentityHubs; needs ~7 GiB)
or `…-postgres.yaml` (persistent IH) to deploy the other topologies. The
`-local-0.17.0` overlay applies to all three.

## Verifying the seed

```bash
kubectl -n umbrella logs job/umbrella-dataprovider-post-install-identityhub-seed | grep "SEED SUMMARY"
# [ih-seed]  SEED SUMMARY: 4 participants provisioned successfully
```

Each of the four participants should hold four ISSUED credentials. With the
postgres IH you can confirm directly:

```bash
kubectl -n umbrella exec umbrella-identityhub-postgresql-0 -- sh -c \
  'PGPASSWORD=password psql -U user -d ih -tAc \
   "SELECT participant_context_id, count(*) FROM credential_resource GROUP BY 1 ORDER BY 1;"'
```

## End-to-end data transfer check (DCP) — Test Case 1

The seed only *provisions* identities. To validate the **full** flow — catalog
→ contract negotiation → transfer → fetching the asset bytes through the
consumer data plane — run the smoke test:

```bash
# kind with host ports 80/443 mapped:
INGRESS_IP=127.0.0.1 ./hack/dcp-data-transfer-smoke.sh
```

A green run ends with `FULL DCP DATA TRANSFER SUCCEEDED` and proves a consumer
fetched a provider asset entirely over DCP — i.e. Test Case 1 from #1609. The
test is stage-aware; on failure it prints exactly which DCP stage broke:

| Failing stage        | What it means                                                                 |
|----------------------|-------------------------------------------------------------------------------|
| `catalog`            | STS auth / VP presentation / trusted-issuer / credential issuance not working |
| `negotiation`        | policy not satisfied or presented credential rejected                         |
| `transfer:*`         | EDR not issued / transfer process did not start (e.g. BDRS BPN resolution)    |
| `fetch`              | data-plane proxy or EDR token problem                                         |

Every input is an env-var override, so the same script validates each profile:

```bash
# shared in-memory / postgres IH (default PROVIDER_DID = the shared IH host):
INGRESS_IP=127.0.0.1 ./hack/dcp-data-transfer-smoke.sh

# per-participant topology (provider on its own IH host):
INGRESS_IP=127.0.0.1 \
  PROVIDER_DID=did:web:ih-provider.tx.test:BPNL00000003AYRE \
  ./hack/dcp-data-transfer-smoke.sh

# stub profile:
PROVIDER_DID=did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003AYRE \
  ./hack/dcp-data-transfer-smoke.sh
```

## Troubleshooting

**`helm install` fails: "only ONE wallet may be enabled at a time".**
The 3-way validator (`_wallet-validate.tpl`) caught two wallets enabled at once.
Use exactly one of the shipped profile files.

**The smoke test fails once at `transfer:edr-cache` ("No BPN entry found for
agreement"), then passes on re-run.** This is the cold-BDRS-cache race (see
*Known limitations* L2). The smoke test already re-negotiates once to warm the
cache; a manual Bruno run may need a single retry of the transfer.

**Seed `WARN: … never reached ISSUED … after 40s` on the postgres IH.** The
postgres IH issues a little slower than the seed's poll window; the credentials
still land. Confirm with the `credential_resource` query above.

## Known limitations

| ID  | Limitation                                                                                          | Workaround / status                                                                                          |
|-----|-----------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| L1  | The validated flow needs the EDC-0.17.0 stack, not yet on a public release channel.                 | Use the `-local-0.17.0` overlay with pre-loaded images (see [Version requirement](#version-requirement)).    |
| L2  | First negotiation after a fresh install can lose a race against the connector's async BDRS lookup.  | Transient; the smoke test auto-retries. Subsequent transfers reuse the warmed BdrsClient cache.              |
| L3  | The in-memory IH (shared / per-participant) loses ParticipantContexts + credentials on pod restart. | Re-seed (re-run the seed Job) after a restart, or use the **postgres** profile (state persists).             |
| L4  | The per-participant profile runs four IdentityHub JVMs (~7 GiB).                                     | Use the shared profile for light testing; disable `dataconsumerTwo` + `identity-hub-consumer2` on small nodes.|

## Teardown

```bash
helm uninstall umbrella -n umbrella
kubectl delete ns umbrella
```

## NOTICE

This work is licensed under the
[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/legalcode).
