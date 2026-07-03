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

It targets a **local prod-alike sandbox** (Minikube / kind on a ≈12–36 GB node), not
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
| `values-persistent-local.yaml` | Postgres PVCs (connectors + CentralIDP) + widened startup probes (issuer, BDRS, connector control-plane). |
| `values-vault-prod-local.yaml` | All three Vaults in **prod mode** (PVC file storage + init/unseal + a fixed-id token) — Phase 2. |

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

- disables `server -dev` and backs `/vault/data` with a **PVC** (file storage);
- replaces the dev seeding `postStart` with an **idempotent bootstrap**: run
  `vault operator init` **once** (persisting the single unseal key + root token on
  the PVC), **unseal on every (re)start**, enable the KV-v2 engine at `secret/`, and
  create a Vault token with a **fixed, known id** (`txedcvaulttoken`) under a
  secret-RW policy;
- raises `max_lease_ttl` so that fixed token gets a ~10-year TTL instead of Vault's
  768h default.

The **fixed-id token** is the key simplification: because the id is chosen (not the
random root token a prod Vault generates at init), every consumer keeps using a
known value baked into config at template time — the connector EDC client
(`EDC_VAULT_HASHICORP_TOKEN`), each IdentityHub's Vault client, and the wallet-mode
ConfigMap `vaultToken` the seeding Jobs read. No runtime token propagation via k8s
Secrets is needed.

## Phase 3 — BDRS (not yet done)

BDRS (`bdrs-server-memory`) is still in-memory. There is **no upstream persistent
BDRS chart**, so making it durable means packaging one from the upstream
`bdrs-server` source. Its BPN→DID directory is **derived config** — re-seeded from
`bdrs-server-memory.seeding.bpnList` by the `post-install-bdrs-setup` hook on every
install/upgrade — so it is not primary state; `values-persistent-local.yaml` only
widens its probe so it stays up (a BDRS **pod** restart still loses the directory
until Phase 3 lands). The submodel backend is likewise in-memory seeded test data.

## Persistence boundary — what survives what

| Component | Store | Survives pod restart | Survives Docker/VM restart |
| --- | --- | --- | --- |
| Connector control/data plane DBs | PostgreSQL + PVC | yes | yes |
| IdentityHub ParticipantContexts, credentials, keypairs | PostgreSQL + PVC | yes | yes |
| IssuerService DB | PostgreSQL + PVC | yes | yes |
| CentralIDP (Keycloak) | PostgreSQL + PVC | yes | yes |
| Vault secrets (edc-wallet-secret, signing keys, IH + issuer keys) | Vault prod, file storage + PVC | yes (re-unseals from PVC) | yes |
| **BDRS directory** | in-memory (derived) | **no** (re-seeded on install/upgrade) | **no** |
| Submodel backend data | in-memory (seeded test data) | **no** (re-seeded on install) | **no** |

After Phases 1 + 2, **all primary state is durable**; only *derived* data (the BDRS
directory, submodel test data) is still ephemeral, and both are re-provisioned on
install.

## Verification

Verified live on kind (per-participant-postgres + persistence + vault-prod):

- **One-shot install** — `helm ... status` reports `deployed` with no manual steps.
- **DCP transfer** — `hack/dcp-data-transfer-smoke.sh` (catalog → negotiation
  FINALIZED → transfer → fetch) passes.
- **IdentityHub durability** — deleting both IdentityHub pods **and** both IdentityHub
  Postgres pods leaves each DB unchanged (participant contexts / credentials /
  keypairs / DIDs counts identical) and the smoke test passes again with **no
  re-seed**.
- **Vault durability** — deleting all three Vault pods at once leaves every secret
  byte-identical (they re-unseal from the PVC via `postStart`) and the smoke test
  passes again.

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
- **Not yet fully "no-in-memory".** BDRS + the submodel backend remain in-memory
  (Phase 3); both hold re-seeded derived data, not primary state.

## Related

- [Data Exchange with Real IdentityHub](data-exchange-identity-hub.md) — deploy
  mechanics, image build, seeding, DCP smoke test, and the full profile list.
- Overlays: [values-persistent-local.yaml](../../../../charts/values-persistent-local.yaml),
  [values-vault-prod-local.yaml](../../../../charts/values-vault-prod-local.yaml).

## NOTICE

This work is licensed under the
[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/legalcode).
