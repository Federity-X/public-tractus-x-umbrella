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
`identityHub` mode there are mutually-exclusive Holder-Wallet variants
(enforced by `charts/umbrella/templates/_wallet-validate.tpl`):

| Profile (`-f charts/…`)                                                 | Wallet chart                                    | Topology / store                                              |
| ----------------------------------------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------- |
| `values-test-data-exchange.yaml` (default)                              | `ssi-dim-wallet-stub`                           | stub, no DCP seeding                                          |
| `values-test-data-exchange-identity-hub.yaml`                           | `tractusx-identityhub-memory` (`identity-hub`)  | **shared** in-memory IH (one multi-tenant host)              |
| `values-test-data-exchange-identity-hub-per-participant.yaml`           | `tractusx-identityhub-memory` ×2                | **per-participant** — provider + consumer1, each on its own IH (in-memory) |
| `values-test-data-exchange-identity-hub-postgres.yaml`                  | `tractusx-identityhub` (`identity-hub-postgres`)| **persistent shared** IH backed by PostgreSQL                |
| `values-test-data-exchange-identity-hub-per-participant-postgres.yaml`  | `tractusx-identityhub` ×2                        | **persistent per-participant** — provider + consumer1, each on its own PostgreSQL-backed IH |

The last profile is the per-participant topology on the **persistent** IH variant
(Phase 1 of the prod-alike "no-in-memory" build): each IdentityHub's
ParticipantContexts + issued credentials live in its own PVC-backed PostgreSQL and
survive a pod restart (the `-memory` per-participant profile loses them on any
restart and must be re-seeded). It reuses the same ingress hosts, DIDs and
connector wiring as the in-memory per-participant profile — only the IH backing
store + in-cluster service names change.

All identityHub profiles share one IssuerService (`tractusx-issuerservice`,
postgres variant — its bundled `database` attestation is required by the DCP
issuance walkthrough). When an identityHub profile is selected, umbrella:

1. renders a `<release>-wallet-mode` ConfigMap with the participant set
   (`operator`, `provider`, `consumer1`, `consumer2` for the shared and postgres
   profiles; the per-participant profile trims this to `provider` + `consumer1`),
   their derived DIDs, IdentityHub credential-service URLs, and the issuer DID;
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

> **Version naming.** "EDC 0.17.0" is the upstream *EDC platform* version. The
> Tractus-X artifacts built on it carry their own tags: the connector is
> `tractusx-connector 0.13.0` (the in-flight images are tagged `0.13.0-SNAPSHOT`),
> and the released IdentityHub/IssuerService line is `v0.3.2` (the in-flight build
> is from PR #309). "0.17.0-aligned" throughout this guide means *built on EDC
> 0.17.0*, not a Tractus-X `0.17.0` release.

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
- `/etc/hosts` entries for `*.tx.test` (see the per-OS Cluster Setup guide —
  [linux](../../linux/setup/README.md) · [mac](../../mac/setup/README.md) ·
  [windows](../../windows/setup/README.md)); in identityHub mode you additionally
  need:

```hosts
127.0.0.1  identity-hub.tx.test
127.0.0.1  identity-hub-admin.tx.test
127.0.0.1  issuer-service.tx.test
```

(The per-participant profile also needs `ih-provider.tx.test`, `ih-provider-admin.tx.test` and `ih-consumer1.tx.test`.)

## Single-command deploy

Pick one profile. Shared in-memory IH (the lightest):

```bash
# One-time on a fresh clone: add every required helm repo and recursively
# fetch chart dependencies (.tgz archives + Chart.lock are git-ignored).
bash hack/helm-dependencies.bash

helm install umbrella charts/umbrella \
  --namespace umbrella --create-namespace --timeout 25m \
  -f charts/values-test-data-exchange-identity-hub.yaml \
  -f charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml
```

Swap the first `-f` for `…-per-participant.yaml` (provider + consumer1, each on
its **own** IdentityHub), `…-postgres.yaml` (persistent shared IH), or
`…-per-participant-postgres.yaml` (persistent per-participant — each holder on its
own PostgreSQL-backed IH) to deploy the other topologies. The `-local-0.17.0`
overlay applies to all of them.

## Verifying the seed

```bash
kubectl -n umbrella logs job/umbrella-dataprovider-post-install-identityhub-seed | grep -A6 "SEED SUMMARY"
# [ih-seed]  SEED SUMMARY: 4 participants provisioned successfully
#   ...
#   Credential issuance (steps 8/9): 16 ISSUED, 0 NOT issued
#   All declared credentials reached ISSUED.
```

The SEED SUMMARY now reports issuance **loudly**: it lists `N ISSUED, M NOT
issued` and, if any are missing, prints each one as `*** PARTIAL ISSUANCE ***`.
(steps 8 and 9 in the seed output are the credential *request* and *retrieve* steps of
the upstream [DCP API walkthrough](https://github.com/eclipse-tractusx/tractusx-identityhub/tree/main/docs/usage/dcp-api-walkthrough).)
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

> **Prefer a GUI / step-by-step requests?** The same flow is available as a
> single, self-contained Postman collection (with dynamic variable threading and
> self-polling) — see [docs/common/api/postman/](../../../common/api/postman/).

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

Both **postgres** profiles (`…-postgres.yaml` shared and
`…-per-participant-postgres.yaml`) avoid step 1 entirely — their ParticipantContexts
and credentials persist across IdentityHub pod restarts (see *Known limitations* L3).
The in-memory BDRS still loses its directory on a BDRS restart until Phase 3
(persistent BDRS) lands.

## Admin panel (per-participant-plus overlay)

The [`fx-connector-ui`](https://github.com/Federity-X/fx-connector-ui) admin panel drives
this per-participant deployment (manage assets/policies/contract-definitions, browse and
consume catalogs over DCP, inspect wallets and credentials, and administer the issuer).

To expose everything the panel needs, layer the **plus** overlay (consumer1 admin ingress +
CentralIDP) and point CentralIDP at your locally-built init-container image. For a **durable,
prod-alike** build on a larger node (≈36 GB), also add the persistence overlay
(`values-persistent-local.yaml`) — omit that one `-f` for the lean, ephemeral build:

```bash
helm install umbrella charts/umbrella \
  -f charts/values-test-data-exchange-identity-hub-per-participant.yaml \
  -f charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml \
  -f charts/values-test-data-exchange-identity-hub-per-participant-plus.yaml \
  -f charts/values-persistent-local.yaml \
  --set centralidp.realmSeeding.initContainer.image.name=umbrella-init-container:be241 \
  --set centralidp.realmSeeding.initContainer.image.pullPolicy=Never \
  --namespace umbrella --create-namespace --timeout 25m
```

(Build `umbrella-init-container:be241` from `init-container/` and `kind load` it first — it
carries the panel's realm client + `login_theme`. Drop the `-f values-persistent-local.yaml`
line for a lean/ephemeral run.)

For the **prod-alike "no-in-memory" durable build**, swap the two in-memory IH `-f`
files for their PostgreSQL counterparts — `…-per-participant-postgres.yaml` (base)
and `…-per-participant-postgres-plus.yaml` (plus overlay) — keeping the same
`-local-0.17.0` and `values-persistent-local.yaml` overlays:

```bash
helm install umbrella charts/umbrella \
  -f charts/values-test-data-exchange-identity-hub-per-participant-postgres.yaml \
  -f charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml \
  -f charts/values-test-data-exchange-identity-hub-per-participant-postgres-plus.yaml \
  -f charts/values-persistent-local.yaml \
  --set centralidp.realmSeeding.initContainer.image.name=umbrella-init-container:be241 \
  --set centralidp.realmSeeding.initContainer.image.pullPolicy=Never \
  --namespace umbrella --create-namespace --timeout 25m
```

This gives each holder its **own** PVC-backed PostgreSQL IdentityHub (state survives
IH/DB pod restarts). Signing keys still live in a dev-mode Vault, so a Vault restart
still wipes them until Phase 2 (Vault → prod mode); BDRS is still in-memory until
Phase 3. See the handoff §7 for the full durability roadmap.

The overlay ([`…-per-participant-plus.yaml`](../../../../charts/values-test-data-exchange-identity-hub-per-participant-plus.yaml),
see its header for full notes) adds:

- **consumer1 IdentityHub admin ingress** (`ih-consumer1-admin.tx.test`) so the panel's
  Wallet page works for consumer1, not just the provider. No new pod. *Validated.*
- **CentralIDP** (Keycloak) for the panel's OIDC login. The client `fx-connector-ui` +
  `participant`/`role` claim mappers + a per-client `login_theme` + test users live in this
  repo's realm import (`init-container/iam/centralidp/CX-Central-realm.json`), baked into the
  `umbrella-init-container` image — rebuild it locally after editing the realm. *Validated
  live (12 GiB VM): the panel's Keycloak login works and maps participant/role.* The issuer
  admin API (`issuer-service-admin.tx.test/api/admin`) is exposed by the defaults.
- **`values-persistent-local.yaml`** (durable builds) gives the connector + CentralIDP
  Postgres PVCs so DBs survive restarts, and widens the issuer-service startup probe (a
  PVC-attach delay otherwise flaps it and breaks credential seeding). ~0 extra RAM. NOTE: full
  restart durability also needs Vault out of dev mode — see the handoff §7b.

The panel repo's [docs/HANDOFF-BE-241.md](https://github.com/Federity-X/fx-connector-ui/blob/feature/BE-241-test-all-features/docs/HANDOFF-BE-241.md)
is the end-to-end runbook (deploy → per-install key extraction → run → verify → the
deferred live-OIDC step).

## Known limitations

| ID  | Limitation                                                                                          | Workaround / status                                                                                          |
|-----|-----------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| L1  | The validated flow needs the EDC-0.17.0 stack, not yet on a public release channel.                 | Use the `-local-0.17.0` overlay with built-from-source images (see [Version requirement](#version-requirement)). |
| L2  | First negotiation after a fresh install can lose a race against the connector's **async** BDRS lookup. | Transient; the smoke test auto-retries and subsequent transfers reuse the warmed BdrsClient cache. Upstream connector timing gap (async BPN resolution vs. terminal transfer state) — to be filed against [tractusx-edc](https://github.com/eclipse-tractusx/tractusx-edc/issues); no umbrella-side fix. |
| L3  | Memory-lean defaults are **not restart-durable**: Postgres runs `persistence: false`, the IdentityHubs run the `-memory` chart, and Vault runs `server -dev` (in-memory), so a pod / Docker / VM restart wipes DBs + wallet state + secrets. | On a small node, [re-seed](#re-seeding-after-a-pod-restart) or clean-reinstall after a restart. On a **large node (≈36 GB) prefer a durable prod-alike build**: use a **postgres** IH profile (`…-postgres.yaml` or `…-per-participant-postgres.yaml`, Phase 1) so ParticipantContexts + credentials persist, enable Postgres `persistence.enabled` per component (`values-persistent-local.yaml`), **and** take Vault out of dev mode (Phase 2: `vault.server.dev.enabled: false` + `dataStorage.enabled` + an init/unseal step, since prod Vault starts sealed and the dev-token secret-seeding must be adapted). BDRS persistence is Phase 3. Full recipe: the fx-connector-ui handoff §7. |
| L4  | Per-participant runs one IdentityHub JVM **per participant**, so it scales with participant count. The shipped profiles (in-memory and postgres) are deliberately **2 participants** (provider + consumer1) to fit a single node — a 4-participant variant over-contends the node (the provider data-backend loses the startup CPU race against the IdentityHub JVMs and crashloops). The postgres per-participant profile additionally runs one bundled PostgreSQL **per** IdentityHub (distinct `nameOverride`s), adding ~2 lightweight DB pods. | Keep per-participant at 2; for more participants, give the cluster proportionally more CPU/memory, or use the shared / persistent-shared profile (single multi-tenant IdentityHub). |

## Teardown

```bash
helm uninstall umbrella -n umbrella
kubectl delete ns umbrella
```

## Related documentation

Everything that makes up the `wallet.mode=identityHub` data-exchange (this guide
is the entry point):

**Profiles** (`-f charts/…`, layered with the image overlay):

- [Shared in-memory IdentityHub](../../../../charts/values-test-data-exchange-identity-hub.yaml) — `values-test-data-exchange-identity-hub.yaml`
- [Per-participant (provider + consumer1)](../../../../charts/values-test-data-exchange-identity-hub-per-participant.yaml) — `…-per-participant.yaml`
- [Persistent / PostgreSQL IdentityHub](../../../../charts/values-test-data-exchange-identity-hub-postgres.yaml) — `…-postgres.yaml`
- [Local-image overlay (EDC-0.17.0 stack)](../../../../charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml) — `…-local-0.17.0.yaml`
- [Per-participant-plus overlay (admin panel: consumer1 admin ingress + CentralIDP)](../../../../charts/values-test-data-exchange-identity-hub-per-participant-plus.yaml) — `…-per-participant-plus.yaml`
- [Persistence overlay (durable/prod-alike storage + issuer-probe fix)](../../../../charts/values-persistent-local.yaml) — `values-persistent-local.yaml`

**Tooling and templates:**

- [DCP data-transfer smoke test](../../../../hack/dcp-data-transfer-smoke.sh) — `hack/dcp-data-transfer-smoke.sh`
- [Postman collection](../../../common/api/postman/) — the same DCP flow as a runnable, self-contained Postman collection (see its [README](../../../common/api/postman/README.md))
- [IdentityHub seeding Job](../../../../charts/tx-data-provider/templates/post-install-identityhub-seed.yaml) — the DCP provisioning hook
- [BDRS directory-seeding hook](../../../../charts/umbrella/templates/post-install-bdrs-setup.yaml)
- Wallet helpers: [`_wallet-derive.tpl`](../../../../charts/umbrella/templates/_wallet-derive.tpl) (per-participant DIDs/URLs) · [`_wallet-validate.tpl`](../../../../charts/umbrella/templates/_wallet-validate.tpl) (wallet mutual-exclusion + image-overlay guard) · [`configmap-wallet-mode.yaml`](../../../../charts/umbrella/templates/configmap-wallet-mode.yaml) (derived wallet ConfigMap)

**Deployment:**

- [Staging / Production Deployment (HTTPS)](./staging-production-deployment.md) — taking `wallet.mode=identityHub` to a real cluster over HTTPS (cert-manager TLS, persistence, real secrets, hardening checklist)

**Background / concepts:**

- [ECOSYSTEM-GUIDE.md](../../../../ECOSYSTEM-GUIDE.md) — DCP / `wallet.mode` concepts and the stub-vs-IdentityHub trust model

**Internal working notes** (provenance only — not part of the user-facing deliverable, and partly historical):

- [#1609 plan](../../../internal/plan-1609-identityhub-connector-bundle.md) — design rationale, version strategy, and PR-positioning note
- [How the umbrella Helm charts work](../../../internal/how-tractus-x-umbrella-helm-charts-work.md) — chart composition reference
- [Phase-9 local deploy & test findings](../../../common/concept/1609-local-test-findings.md) — historical defect log (superseded; see the plan)

## NOTICE

This work is licensed under the
[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/legalcode).
