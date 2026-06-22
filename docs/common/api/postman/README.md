<!--
SPDX-License-Identifier: CC-BY-4.0
Copyright (c) 2026 Contributors to the Eclipse Foundation
-->

# Postman collection — DCP data transfer (per-participant IdentityHub)

A single, self-contained, runnable Postman collection that demonstrates the **full
Decentralized Claims Protocol (DCP) data-transfer flow** end-to-end against the
umbrella IdentityHub **per-participant** profile (provider and consumer1 each on
their own IdentityHub). It is the Postman equivalent of
[`hack/dcp-data-transfer-smoke.sh`](../../../../hack/dcp-data-transfer-smoke.sh).

## File

| File | Purpose |
|---|---|
| `umbrella-dcp-per-participant.postman_collection.json` | The whole thing — 11 requests in 3 folders **plus all variables** (collection-scoped). No separate environment file. |

All configuration lives in the collection's **Variables** tab (snake_case:
`provider_mgmt`, `consumer_mgmt`, `provider_api_key`, `provider_did`, …). Import the
one file and edit values there — there is no environment to select.

## What it does

The requests are grouped into three folders; run them top-to-bottom. Each step's
test script extracts the value the next step needs, so nothing is copied by hand:

- **1-5 — Provider Setup** — seed submodel data, create asset, access policy, usage
  policy, contract definition (unique ids per run via the request-1 pre-request).
- **6-8 — Catalog & Negotiation** — request catalog (`offer_id`), start EDR
  negotiation (`negotiation_id`), poll until `FINALIZED` (fails fast on `TERMINATED`).
- **9-11 — Transfer & Fetch** — query the cached EDR (`transfer_process_id`), get the
  data-plane `edr_endpoint` + `edr_token`, fetch the asset bytes and assert the
  payload contains `data_marker` (proves a real end-to-end transfer).

Dynamic handling: `offer_id → negotiation_id → transfer_process_id → edr_endpoint +
edr_token` are set by test scripts; steps 8/9/10 self-poll via
`pm.execution.setNextRequest`, and step 9 re-negotiates once on the cold-BDRS-cache
race (matching the smoke test).

## Prerequisites

- A running umbrella deployed with the per-participant profile + the image overlay
  (see the [deploy guide](../../../user/common/guides/data-exchange-identity-hub.md)).
- Postman (or `newman`), and a way to reach the ingress hosts. The collection
  handles this with the **`ingress_ip`** variable (the Postman equivalent of the
  smoke test's `INGRESS_IP`):
  - **Default `ingress_ip = 127.0.0.1`** — a collection pre-request rewrites each
    request to connect to that IP while sending the real host as a `Host` header
    (ingress-nginx routes by Host). Works out of the box on kind with host ports
    80/443 mapped, **without any `/etc/hosts` edits**.
  - If you have real DNS or `/etc/hosts` entries for `*.tx.test`, **clear
    `ingress_ip`** and requests go to the hostnames directly.

## Run it

**Postman app:** import the single collection file, then either send the 11 requests
in order, or use the **Collection Runner** with a **~2000 ms delay** between requests
(so the self-polling steps have time between attempts).

**newman (CLI):**

```bash
newman run docs/common/api/postman/umbrella-dcp-per-participant.postman_collection.json \
  --delay-request 2000
```

(No `-e` — the variables are in the collection.) A green run ends with the fetch
assertion passing and `FULL DCP DATA TRANSFER SUCCEEDED` in the console.

> Validated with `newman` 6.x against the per-participant profile on kind
> (`ingress_ip=127.0.0.1`): all requests and assertions pass, ending in
> `FULL DCP DATA TRANSFER SUCCEEDED`.

## Troubleshooting

**Step 9 returns an empty array even though the negotiation is FINALIZED.** The
negotiation succeeded, but the transfer that runs after it hasn't produced an EDR
yet. Two causes:

- *Timing* — the transfer caches the EDR a few seconds after FINALIZED. Re-send
  step 9. (The Collection Runner / newman poll automatically; a manual **Send**
  does not — see the note below.)
- *Transfer terminated* — run **9b - Diagnose Transfer State**. If it reports
  `TERMINATED: No BPN entry found for agreement`, the in-memory BDRS directory is
  missing the BPN→DID mapping (it is only seeded on install/upgrade and is lost if
  the BDRS pod restarts). Re-seed BDRS by re-running the `post-install-bdrs-setup`
  hook (e.g. `helm upgrade …`) — see the deploy guide's
  [Re-seeding after a pod restart](../../../user/common/guides/data-exchange-identity-hub.md#re-seeding-after-a-pod-restart)
  runbook — then re-run from step 7.

> **Manual Send vs Collection Runner.** The self-polling and auto-re-negotiate in
> steps 8/9/10 use `setNextRequest`, which only takes effect in the **Collection
> Runner** and **newman** — not when you click **Send** on a single request. When
> sending manually, re-send the poll requests yourself (and step 7 to re-negotiate).

## Use it for the shared or postgres profile

The connector endpoints are the same across profiles; only the provider's DID host
differs. To point the collection at the **shared** or **postgres** profile, change
just one variable:

```
provider_did = did:web:identity-hub.tx.test:BPNL00000003AYRE
```

(and you no longer need the `ih-*.tx.test` hosts). Everything else is identical.
