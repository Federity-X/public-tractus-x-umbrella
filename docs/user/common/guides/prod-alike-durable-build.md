# Prod-alike durable build (the "no-in-memory" stack)

The umbrella's lean/test defaults optimise for a fast, disposable sandbox: most
stores run in-memory or on `emptyDir`, and HashiCorp Vault runs `server -dev`
(in-memory). That is ideal for CI and quick demos, but a pod / Docker / VM restart
wipes state — DBs, wallet ParticipantContexts + credentials, and Vault secrets — so
the dataspace must be reinstalled or re-seeded.

This guide describes the **prod-alike durable build**: the same per-participant
IdentityHub dataspace, but with every component that holds **primary state** backed
by durable storage, so it survives restarts. It is composed as a stack of opt-in
`-f` overlays on top of the per-participant-postgres profile — add an overlay to
gain durability, drop it to go back to the fast/ephemeral behaviour.

It targets a **local prod-alike sandbox** (Minikube / kind on a ≈12–24 GiB Docker VM), not
real production — see [Caveats](#caveats).

> Deploy mechanics (image prerequisites, ingress hosts, seeding, the DCP smoke test)
> live in the companion guide
> [Data Exchange with Real IdentityHub](data-exchange-identity-hub.md); this guide is
> the durability reference.

## The overlay stack

```bash
helm install umbrella charts/umbrella \
  -f charts/values-test-data-exchange-identity-hub-per-participant-postgres.yaml \
  -f charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml \
  -f charts/values-test-data-exchange-identity-hub-per-participant-postgres-plus.yaml \
  -f charts/values-persistent-local.yaml \
  -f charts/values-vault-prod-local.yaml \
  --set centralidp.realmSeeding.initContainer.image.name=umbrella-init-container:be241 \
  --set centralidp.realmSeeding.initContainer.image.pullPolicy=Never \
  --namespace umbrella --create-namespace --timeout 25m
```

| Overlay (`-f charts/…`) | Role |
| --- | --- |
| `values-test-data-exchange-identity-hub-per-participant-postgres.yaml` | Base topology: provider + consumer1, each on its **own PostgreSQL-backed** IdentityHub (Phase 1). |
| `values-test-data-exchange-identity-hub-local-0.17.0.yaml` | In-flight EDC-0.17.0 image pins (built from source; see the companion guide). |
| `values-test-data-exchange-identity-hub-per-participant-postgres-plus.yaml` | Admin-panel extras: consumer1 IdentityHub admin ingress + CentralIDP (Keycloak). |
| `values-persistent-local.yaml` | Postgres PVCs (connectors + CentralIDP) + the **submodel backend on PostgreSQL** (its JPA image, Phase 3) + widened startup probes (issuer-service, connector control-plane, and `bdrs-server-memory` — inert when the durable profile runs the postgres `bdrs-server`). |
| `values-vault-prod-local.yaml` | All three connector/issuer Vaults in **prod mode** (Raft integrated storage on a PVC + init/unseal + a fixed-id token) — Phase 2. |

## Phase 1 — persistent per-participant IdentityHubs

Each participant's IdentityHub is the postgres-backed `tractusx-identityhub` chart
(not the `-memory` variant), with its **own** bundled PostgreSQL (distinct
`nameOverride` + `jdbcUrl` per IH to avoid the bitnami label clash). A holder's
ParticipantContexts + issued credentials + keypairs live in that PVC-backed DB and
survive both an IdentityHub pod restart and a Postgres pod restart.

Each IdentityHub authenticates to its **participant's connector Vault**
(`edc-dataprovider-vault` / `edc-dataconsumer-1-vault`), not a single shared Vault:
two IdentityHubs sharing one Vault both create a `super-user` ParticipantContext
under the same token alias, so the second overwrites the first and the seeding Job's
scraped key then fails with `401` on the Identity API. (The single-IH shared-postgres
profile has no peer to collide with; the in-memory IHs use per-process in-memory
Vaults.)

## Phase 2 — Vaults in prod mode

`values-vault-prod-local.yaml` takes all three per-participant Vaults out of dev
mode: the two connector Vaults (which hold `edc-wallet-secret`, the EDC
token-signing keys, and — since Phase 1 — each IdentityHub's STS/keypair secrets)
and the issuer-service Vault (which holds the issuer's VC-signing keypair; a dev-mode
restart would regenerate it and break verification of already-issued credentials).

Per Vault the overlay:

- disables `server -dev` and backs `/vault/data` with a **PVC** using **Raft
  integrated storage** (HashiCorp's recommended production backend; single-voter on
  the sandbox — a Vault restart re-unseals and replays the Raft log from the PVC);
- replaces the dev seeding `postStart` with an **idempotent bootstrap**: run
  `vault operator init` **once** (persisting the single unseal key + root token on
  the PVC), **unseal on every (re)start**, enable the KV-v2 engine at `secret/`, and
  create a Vault token with a **fixed, known id** (`txedcvaulttoken`) under a
  secret-RW policy;
- creates that token as a **periodic** token (`-period`, ~1y) rather than a plain
  fixed-TTL one: EDC's scheduled token-renew drives a plain-TTL token's lease *down* to
  the small renew increment (~300s), so one missed renewal kills it and DCP breaks; a
  periodic token has its TTL **reset to the full period on every renew** (see the
  [Vault sandbox-vs-production guide](vault-sandbox-vs-production.md)).

The **fixed-id token** is the key simplification: because the id is chosen (not the
random root token a prod Vault generates at init), every consumer keeps using a
known value baked into config at template time — the connector EDC client
(`EDC_VAULT_HASHICORP_TOKEN`), each IdentityHub's Vault client, and the wallet-mode
ConfigMap `vaultToken` the seeding Jobs read. No runtime token propagation via k8s
Secrets is needed.

## Phase 3 — submodel backend (done) + BDRS (done)

**Submodel backend — done.** `simple-data-backend` now backs its store with Spring
Data JPA: the embedded H2 default keeps lean profiles in-memory, and this durable
overlay points it at a bundled **PostgreSQL** (its `:jpa` image + `SPRING_DATASOURCE_*`
env), so seeded submodel documents survive a restart. This closes the gap where a
submodel-backend restart wiped all data while the Postgres-backed DTR kept advertising
the now-dangling paths (every data pull then `500`'d until a manual re-seed).

**BDRS — done.** The postgres profiles swap `bdrs-server-memory` for the
PostgreSQL-backed **`bdrs-server`** chart (both render as service `bdrs-server`, so
nothing downstream changes). Its BPN→DID directory now lives in a PVC-backed
PostgreSQL (`{release}-bdrs-postgresql`) and survives a BDRS **pod** restart — the
`post-install-bdrs-setup` hook only seeds it once on install, not on every restart.
BDRS reads its DB creds + management API key from its own small Vault (`bdrs-vault`),
kept in **dev mode on purpose**: unlike the connector Vaults (which hold the
dynamically-generated, unrecoverable STS clientSecret and therefore need Raft
persistence), this Vault holds only static, re-seedable values, so an idempotent
`postStart` re-seeds them on every start and a restart loses nothing.

## Persistence boundary — what survives what

| Component | Store | Survives pod restart | Survives Docker/VM restart |
| --- | --- | --- | --- |
| Connector control/data plane DBs | PostgreSQL + PVC | yes | yes |
| IdentityHub ParticipantContexts, credentials, keypairs | PostgreSQL + PVC | yes | yes |
| IssuerService DB | PostgreSQL + PVC | yes | yes |
| CentralIDP (Keycloak) | PostgreSQL + PVC | yes | yes |
| Vault secrets (edc-wallet-secret, signing keys, IH + issuer keys) | Vault prod, Raft storage + PVC | yes (re-unseals from PVC) | yes |
| Submodel backend data | PostgreSQL + PVC (JPA) | yes | yes |
| BDRS directory | PostgreSQL + PVC (`bdrs-server`) | yes | yes |

After Phases 1 + 2 + 3, **all state is durable** — the connector/IdentityHub/issuer
Postgres, the Vault secrets (Raft), the submodel backend, and the BDRS directory all
survive a pod / Docker / VM restart. The one derived value that is still re-provisioned
rather than persisted is the BDRS **cache** inside each connector (the cold-BDRS-cache
first-transfer retry), which is independent of the BDRS directory store.

## Verification

Verified live on kind (per-participant-postgres + persistence + vault-prod):

- **One-shot install** — `helm ... status` reports `deployed` with no manual steps.
- **DCP transfer** — `hack/dcp-data-transfer-smoke.sh` (catalog → negotiation
  FINALIZED → transfer → fetch) passes.
- **IdentityHub durability** — deleting both IdentityHub pods **and** both IdentityHub
  Postgres pods leaves each DB unchanged (participant contexts / credentials /
  keypairs / DIDs counts identical) and the smoke test passes again with **no
  re-seed**.
- **Vault durability** — deleting all Vault pods at once leaves every secret
  byte-identical (they re-unseal from the Raft PVC via `postStart`) and the smoke test
  passes again.
- **BDRS durability** — deleting the `bdrs-server` pod **and** its Postgres pod leaves
  the BPN→DID directory intact (rows unchanged, directory API returns every BPN) with
  **no re-seed**, and the smoke test passes again.

## Caveats

- **Sandbox-only Vault bootstrap.** The unseal key + root token are stored in
  plaintext at `/vault/data/init.txt` on the PVC (single unseal key, threshold 1),
  and the connector authenticates with a static fixed-id token. Acceptable for a
  local prod-alike sandbox; **not** a production pattern. The full sandbox-vs-prod
  analysis (why we chose this, and the exact production controls — auto-unseal +
  KMS, Kubernetes auth via the Vault Agent Injector, least-privilege policies, Raft
  HA) is in [Vault: sandbox vs production](vault-sandbox-vs-production.md), written
  for the infra team.
- **Startup contention.** The durable stack is heavier (extra Postgres pods). On a
  tight node the startup stampede can delay a JVM past its probe budget; the widened
  probes in `values-persistent-local.yaml` (connector control-plane, issuer, BDRS)
  mitigate this. Prefer ≥12 GiB; the first DCP transfer after a fresh install may hit
  the known cold-BDRS-cache retry (the smoke test auto-retries).
- **Fully "no-in-memory".** With Phase 3 complete, the durable postgres profiles run
  no in-memory primary store: the submodel backend and BDRS are both PostgreSQL-backed
  and the Vaults use Raft. (The lean/CI profiles still use the in-memory variants by
  default — durability is opt-in via the postgres profiles + these overlays.)

## Related

- [Data Exchange with Real IdentityHub](data-exchange-identity-hub.md) — deploy
  mechanics, image build, seeding, DCP smoke test, and the full profile list.
- Overlays: [values-persistent-local.yaml](../../../../charts/values-persistent-local.yaml),
  [values-vault-prod-local.yaml](../../../../charts/values-vault-prod-local.yaml).

## NOTICE

This work is licensed under the
[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/legalcode).
