# Vault: how the sandbox works, and the production path (for the infra team)

This document explains **how HashiCorp Vault is wired in the prod-alike local
sandbox** (the `values-vault-prod-local.yaml` overlay), **why** we made the
choices we did, and — importantly — **what a real production deployment must do
differently**. It is written for the platform/infra team who will review or
productionise this, so the boundary between "sandbox-only convenience" and
"production requirement" is explicit.

> TL;DR: the sandbox deliberately trades Vault security for **self-containment and
> reproducibility** (no external KMS, one node, deterministic install). Every one
> of those trades has a documented production replacement below. **Nothing in the
> sandbox Vault setup should ship to production as-is.**

## What needs Vault

Each participant's EDC connector (control + data plane), its IdentityHub, the
IssuerService, and the post-install seeding Jobs read/write secrets in Vault
(KV v2 at `secret/`): `edc-wallet-secret` (the STS client secret), the EDC
token-signing keys, `aesKey`, and the IdentityHub/issuer key material. If a
component cannot reach Vault or authenticate, DCP breaks immediately
(`Failed to fetch client secret from the vault with alias: edc-wallet-secret`,
then STS `401 invalid_client`).

There are two independent lifecycle concerns: **(1) seal/unseal** and
**(2) authentication**. The sandbox solves both with shortcuts.

## Sandbox design (what the overlay does, and why)

| Concern | Sandbox choice | Why (sandbox) |
| --- | --- | --- |
| **Unseal** | `vault operator init -key-shares=1 -key-threshold=1` runs once in the `postStart`; the **single unseal key + root token are written in plaintext** to `/vault/data/init.txt` on the PVC; every (re)start auto-unseals by reading that file. | No external KMS/HSM needed; a pod restart self-heals; fully reproducible on a laptop/kind. |
| **Auth** | A **static token with a fixed, known id** (`txedcvaulttoken`) under one broad `secret/*` read-write policy, baked into every consumer's config (connector `EDC_VAULT_HASHICORP_TOKEN`, IdentityHub vault client, seed-Job `vaultToken`). | A prod Vault mints a *random* root token at init — unknown at Helm-template time. A chosen id lets every consumer keep a known value in config; no runtime token distribution. |
| **Token lifetime** | A fixed TTL sized to comfortably outlive a sandbox session (~1 year), created at install. | Must outlive a session without a renewal loop (see "Why not a refresh token" below). |
| **Storage** | `file` backend on a single PVC (`standalone` mode, 1 replica). | One node, no HA infra. |
| **Root token** | Left on the PVC (used by the `postStart` on each start). | Convenience — the init/unseal script needs it. |
| **Policy** | One `secret/*` RW policy shared by all workloads. | Simplicity. |
| **TLS** | Disabled (`tls_disable = 1`, in-cluster HTTP). | `.tx.test` sandbox uses HTTP throughout. |

### Why not a refresh/renewable token in the sandbox

EDC's HashiCorp Vault extension *can* auto-renew its token ("scheduled renewal"),
but its **default renewal TTL is 300 seconds** — it drives the token down to a
5-minute lease and keeps it alive by renewing every ~270s. One hiccup in that loop
(GC pause, slow tick, restart lag) and the token dies within five minutes, taking
DCP down with it. In a sandbox that is a *worse* failure mode than a static token,
and it buys **no security** here because the token already sits in plaintext on the
PVC. So the sandbox uses a static token with a TTL long enough to outlive a session.
(This is *not* the production answer — see below.)

> **Operational lesson (why the TTL matters).** An early build created the token
> with an unintentionally short TTL; the connector kept working until the token
> expired, then failed abruptly with `Failed to fetch client secret ... edc-wallet-secret`
> (HTTP 502). Two takeaways baked into the overlay: (1) size the TTL to comfortably
> exceed any sandbox session (~1 year), and (2) **re-issue the token on every Vault
> start** (revoke + create, rather than skip-if-present) so a stale or
> short-lived token can never linger across a redeploy. Neither is a production
> control — in production the Vault Agent obtains and renews the token (below).

## Production requirements (what infra must change)

Each sandbox shortcut maps to a concrete production control. None of these are
optional for a real dataspace deployment.

| Concern | Sandbox | **Production** |
| --- | --- | --- |
| **Unseal** | Shamir 1-of-1, key on disk | **Auto-unseal** via a cloud KMS / HSM (`seal "awskms"`/`gcpckms`/`azurekeyvault`/Transit). Unseal never touches disk; recovery keys are Shamir-split among operators and stored out-of-band. |
| **Auth** | Static token in config | **Kubernetes auth method** (`vault auth enable kubernetes`): each workload presents its **projected ServiceAccount token**; Vault maps SA → role → policy and returns a **short-lived, auto-renewed** token. Delivered by the **Vault Agent Injector** (already deployed in this chart — just unused) via pod annotations. Use **AppRole** only where SA-based identity isn't available. **No static token, no long TTL, nothing baked into config.** |
| **EDC integration** | Reads `EDC_VAULT_HASHICORP_TOKEN` (literal) | Vault Agent logs in (k8s auth), renders the short-lived token into the pod, and **renews it in the background**; EDC reads it at start with its own `scheduled-renew` **disabled** (the agent owns renewal). On pod restart the agent re-authenticates and gets a fresh token. |
| **Authorization** | One `secret/*` RW policy | **Least-privilege per workload** — each connector/IdentityHub gets a policy scoped to only *its own* secret paths, read-only where possible. |
| **Storage / HA** | `file`, 1 replica | **Integrated Raft** (3+ replicas, HA) or Consul, with **TLS**, automated **snapshots/backup**, and disaster-recovery replication. |
| **Root token** | Persisted on PVC | **Revoked** immediately after init; recovery is break-glass only (generate-root with the recovery keys). |
| **Secrets** | Static KV | **Rotation** (signing keys, client secrets), an **audit device** enabled, and **dynamic secrets** for anything that supports them (DB creds, PKI). |
| **Transport** | HTTP | **mTLS** between clients and Vault; ingress/service-mesh policy. |

## How to migrate (sandbox → prod), concretely

1. **Auto-unseal**: add a `seal` stanza (KMS) to the Vault config; drop the
   `operator init`/plaintext-key `postStart`; let Vault auto-unseal. Store recovery
   keys out-of-band.
2. **Enable k8s auth**: `vault auth enable kubernetes` + configure it with the
   cluster's TokenReview API; create one Vault **role per workload SA** bound to a
   least-privilege **policy**.
3. **Switch delivery to the Vault Agent Injector**: annotate the connector /
   IdentityHub / issuer pods (`vault.hashicorp.com/agent-inject`, `role`, and a
   secret template) instead of setting `EDC_VAULT_HASHICORP_TOKEN`; disable EDC's
   `scheduled-renew` so the agent owns renewal.
4. **Least-privilege policies**: replace the single `secret/*` policy with
   per-participant paths.
5. **HA storage + TLS + audit**: Raft (3 nodes), TLS listener, snapshots, audit
   device.
6. **Revoke the root token** and remove any on-disk key material.

The application side (EDC, IdentityHub, IssuerService) needs **no code change** for
any of this — it always just reads a token; only *how the token is obtained and
kept fresh* changes. That is the whole point: the sandbox and production differ only
in the Vault operational layer, which is exactly the layer the infra team owns.

## Working-process summary

- The **application/dataspace behaviour** (DCP flow, credentials, transfers) is
  identical in sandbox and prod — validated in the sandbox and unaffected by the
  Vault operational choices.
- The **Vault operational layer** is deliberately simplified in the sandbox for
  reproducibility, and every simplification has a one-to-one production replacement
  above.
- When productionising, infra changes the operational layer (unseal, auth, HA,
  policies) and leaves the application wiring alone.

See also the [Prod-alike durable build](prod-alike-durable-build.md) guide for how
the Vault overlay fits into the wider no-in-memory stack.

## NOTICE

This work is licensed under the
[CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/legalcode).
