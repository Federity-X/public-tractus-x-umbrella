# Data Exchange with Real IdentityHub (identityHub wallet mode)

This guide shows how to deploy the umbrella data-exchange subset against a
real [tractusx-identityhub](https://github.com/eclipse-tractusx/tractusx-identityhub)
+ IssuerService pair instead of the default
[ssi-dim-wallet-stub](https://github.com/eclipse-tractusx/ssi-dim-wallet-stub),
and run a **full DCP data exchange** (catalog → contract negotiation → transfer
→ fetch) end-to-end.

> **Status (26.06 milestone):** tracked under
> [eclipse-tractusx/sig-release#1609](https://github.com/eclipse-tractusx/sig-release/issues/1609).
> The full DCP data-transfer flow is validated end-to-end on all three
> IdentityHub profiles below (shared, per-participant, and persistent/postgres).
> This guide **demonstrates the fix on the in-flight stack** — the connector
> built from [tractusx-edc `main`](https://github.com/eclipse-tractusx/tractusx-edc)
> (EDC 0.17.0) plus IdentityHub/IssuerService from
> [tractusx-identityhub PR #309](https://github.com/eclipse-tractusx/tractusx-identityhub/pull/309).
> It does **not** wait on upstream releases: it proves the solution now and so
> drives the release sequence — ship `tractusx-connector 0.13.0` → merge IH
> #309 → bump the umbrella pins and drop the overlay. The
> **[Version requirement](#version-requirement)** section gives the reproducible
> build + overlay steps so anyone can re-run the demonstration today.

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

These are **in-flight** — `tractusx-connector 0.13.0` is not yet released and the
IdentityHub EDC-0.17.0 upgrade is open as
[PR #309](https://github.com/eclipse-tractusx/tractusx-identityhub/pull/309). This
guide rides those in-flight builds **on purpose**, to demonstrate the working fix
now rather than wait. The bundle `Chart.yaml`s still pin the released 0.16.0 line
(`tractusx-connector:0.13.0-rc2`, IH/IS `v0.3.2`), which **cannot** complete the
transfer (it predates the plain-`participantContextId` change). A render guard
(`templates/_wallet-validate.tpl`) therefore fails any `wallet.mode=identityHub`
install that does **not** layer the local-image overlay below — so nobody
silently runs the non-working stack.

> **Path to merge:** ship `tractusx-connector 0.13.0` → merge IH #309 → bump the
> bundle `Chart.yaml` pins to the released versions and delete the overlay (and
> its guard) → merge this umbrella change. Until then, build the two images sets
> from source and load them into your cluster as below.

### Build the in-flight images from source

Prerequisites: **JDK 21**, Docker, and a local clone of each repo. (Building is a
one-time step; the images are then reused across installs.)

**1. Connector control/data planes — from `tractusx-edc` `main` (EDC 0.17.0):**

```bash
git clone https://github.com/eclipse-tractusx/tractusx-edc.git
cd tractusx-edc                                   # main = 0.13.0-SNAPSHOT (EDC 0.17.0)

# The `dockerize` task (registered in the root build.gradle.kts) builds each
# runtime image as <module-name>:<version> (+ :latest). JDK 21 is required.
./gradlew -x test \
  :edc-controlplane:edc-controlplane-postgresql-hashicorp-vault:dockerize \
  :edc-dataplane:edc-dataplane-hashicorp-vault:dockerize

# Retag to the names the overlay pins:
docker tag edc-controlplane-postgresql-hashicorp-vault:0.13.0-SNAPSHOT \
           tractusx/edc-controlplane-postgresql-hashicorp-vault:0.13.0-SNAPSHOT
docker tag edc-dataplane-hashicorp-vault:0.13.0-SNAPSHOT \
           tractusx/edc-dataplane-hashicorp-vault:0.13.0-SNAPSHOT
```

**2. IdentityHub + IssuerService — from `tractusx-identityhub` PR #309:**

```bash
git clone https://github.com/eclipse-tractusx/tractusx-identityhub.git
cd tractusx-identityhub
git fetch origin pull/309/head:pr-309 && git checkout pr-309   # EDC 0.17.0 upgrade

# Build the three runtime images (module → image, named after the runtime):
./gradlew -x test \
  :runtimes:identityhub:dockerize \
  :runtimes:identityhub-memory:dockerize \
  :runtimes:issuerservice:dockerize

# Retag to the overlay's names (run `docker images` to confirm the produced
# source tags first — they are named after the runtime module + version):
docker tag identityhub-memory:latest docker-identityhub-memory:latest   # in-memory IH
docker tag identityhub:latest        docker-identityhub:latest          # postgres IH
docker tag issuerservice:latest      docker-issuerservice:latest        # issuer service
```

**3. Load all five images into your cluster** (kind shown; for minikube use
`minikube image load <name>`):

```bash
kind load docker-image \
  docker-identityhub-memory:latest \
  docker-identityhub:latest \
  docker-issuerservice:latest \
  tractusx/edc-controlplane-postgresql-hashicorp-vault:0.13.0-SNAPSHOT \
  tractusx/edc-dataplane-hashicorp-vault:0.13.0-SNAPSHOT \
  --name <cluster>
```

Finally, layer the local-image overlay
[`values-test-data-exchange-identity-hub-local-0.17.0.yaml`](../../../../charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml)
(it pins these images, sets `pullPolicy: Never`, and carries the
`wallet.identityHub.imagesOverridden` sentinel that satisfies the render guard)
on every install — see [Single-command deploy](#single-command-deploy).

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
kubectl -n umbrella logs job/umbrella-dataprovider-post-install-identityhub-seed | grep -A6 "SEED SUMMARY"
# [ih-seed]  SEED SUMMARY: 4 participants provisioned successfully
#   ...
#   Credential issuance (§8/§9): 16 ISSUED, 0 NOT issued
#   All declared credentials reached ISSUED.
```

The SEED SUMMARY now reports issuance **loudly**: it lists `N ISSUED, M NOT
issued` and, if any are missing, prints each one as `*** PARTIAL ISSUANCE ***`.
Each of the four participants should hold four ISSUED credentials (16 total).
Tuning knobs (under `wallet.identityHubSeed` / `wallet`):

| Value                              | Default | Purpose                                                              |
| ---------------------------------- | ------- | ------------------------------------------------------------------- |
| `credentialPollTimeoutSeconds`     | `120`   | how long to poll each credential for state ISSUED (postgres is slow) |
| `strictIssuance`                   | `false` | when `true`, the Job **fails** if any credential is not ISSUED       |
| `wallet.frameworkContractVersion`  | `"1.0"` | version baked into the framework/governance VCs (must match the policy) |

With the postgres IH you can confirm issuance directly:

```bash
kubectl -n umbrella exec umbrella-identityhub-postgresql-0 -- sh -c \
  'PGPASSWORD=password psql -U user -d ih -tAc \
   "SELECT participant_context_id, count(*) FROM credential_resource GROUP BY 1 ORDER BY 1;"'
```

The seed Job is **idempotent**: re-running it (e.g. via `helm upgrade`, or
manually after a restart — see [Re-seeding](#re-seeding-after-a-pod-restart))
tolerates HTTP 409 on every existing ParticipantContext / holder, and a repeated
credential request re-hits the holder-request primary key as a soft no-op. So a
re-seed only fills in what is missing; it never errors on already-provisioned
state.

## End-to-end data transfer check (DCP) — Test Case 1

The seed only *provisions* identities. To validate the **full** flow — catalog
→ contract negotiation → transfer → fetching the asset bytes through the
consumer data plane — run the smoke test:

```bash
# kind with host ports 80/443 mapped:
INGRESS_IP=127.0.0.1 ./hack/dcp-data-transfer-smoke.sh
```

> **First transfer after a fresh install may need a retry.** The connector
> resolves the provider BPN→DID through BDRS **asynchronously**, and the very
> first negotiation can finish before that lookup populates the `BdrsClient`
> cache — the transfer then fails once with `transfer:edr-cache` ("No BPN entry
> found for agreement"). The smoke test already re-negotiates once to warm the
> cache, so it self-heals; a manual (e.g. Bruno) run may need a single retry.
> This is an upstream connector timing gap (async BPN resolution vs. terminal
> transfer state), not an umbrella misconfiguration — see *Known limitations* L2.

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

**Seed SUMMARY reports `PARTIAL ISSUANCE` / `WARN: … never reached ISSUED …`
on the postgres IH.** The postgres IH issues more slowly than the in-memory one.
The credentials usually still land — confirm with the `credential_resource`
query above. If they consistently lag, raise
`wallet.identityHubSeed.credentialPollTimeoutSeconds` (default `120`). Set
`strictIssuance: true` to make the Job fail instead of warn on a partial seed.

**`helm install` fails: "wallet.mode=identityHub needs the EDC-0.17.0-aligned
images …".** The version-mismatch guard fired because the local-image overlay
was not layered. Add `-f charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml`
(and pre-load the images — see [Version requirement](#version-requirement)).

### Re-seeding after a pod restart

The in-memory IH (shared / per-participant) and the in-memory BDRS lose their
state when their pod restarts; the post-install hooks only run on
install/upgrade. To restore a running cluster **without reinstalling**, re-run
the two seed hooks (both are idempotent):

```bash
# 1. Re-provision IdentityHub ParticipantContexts + credentials:
kubectl -n umbrella delete job umbrella-dataprovider-post-install-identityhub-seed 2>/dev/null || true
helm upgrade umbrella charts/umbrella --namespace umbrella --reuse-values \
  -f charts/values-test-data-exchange-identity-hub.yaml \
  -f charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml

# 2. (in-memory BDRS only) confirm the directory was re-seeded:
kubectl -n umbrella logs job/umbrella-post-install-bdrs-setup | tail -5
```

The **postgres** profile avoids step 1 entirely — its ParticipantContexts and
credentials persist across IdentityHub pod restarts (see *Known limitations* L3).

## Known limitations

| ID  | Limitation                                                                                          | Workaround / status                                                                                          |
|-----|-----------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| L1  | The validated flow needs the EDC-0.17.0 stack, not yet on a public release channel.                 | Use the `-local-0.17.0` overlay with built-from-source images (see [Version requirement](#version-requirement)). |
| L2  | First negotiation after a fresh install can lose a race against the connector's **async** BDRS lookup. | Transient; the smoke test auto-retries and subsequent transfers reuse the warmed BdrsClient cache. Upstream connector timing gap (async BPN resolution vs. terminal transfer state) — to be filed against [tractusx-edc](https://github.com/eclipse-tractusx/tractusx-edc/issues); no umbrella-side fix. |
| L3  | The in-memory IH (shared / per-participant) and in-memory BDRS lose state on pod restart.            | [Re-seed](#re-seeding-after-a-pod-restart) after a restart, or use the **postgres** profile (SQL state persists; key durability is still bounded by the shared dev-mode Vault). |
| L4  | The per-participant profile runs four IdentityHub JVMs (~7 GiB).                                     | Use the shared profile for light testing; disable `dataconsumerTwo` + `identity-hub-consumer2` on small nodes.|

## Teardown

```bash
helm uninstall umbrella -n umbrella
kubectl delete ns umbrella
```

## NOTICE

This work is licensed under the
[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/legalcode).
