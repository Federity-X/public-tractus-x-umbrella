<!--
SPDX-License-Identifier: CC-BY-4.0
Copyright (c) 2026 Contributors to the Eclipse Foundation
-->

# Postman collection — DCP data transfer (per-participant IdentityHub)

A runnable, self-verifying Postman collection that demonstrates the **full
Decentralized Claims Protocol (DCP) data-transfer flow** end-to-end against the
umbrella IdentityHub **per-participant** profile (provider and consumer1 each on
their own IdentityHub). It is the Postman equivalent of
[`hack/dcp-data-transfer-smoke.sh`](../../../../hack/dcp-data-transfer-smoke.sh).

## Files

| File | Purpose |
|---|---|
| `umbrella-dcp-per-participant.postman_collection.json` | The 11 requests (provider provisioning + consumer catalog/negotiation/transfer/fetch) |
| `umbrella-dcp-per-participant.postman_environment.json` | Self-contained environment (endpoints, API keys, DIDs, BPN, marker, poll limits) |

## What it does

Run the requests in order. Each step's **test script** extracts the value the
next step needs and stores it as a variable, so nothing is copied by hand:

1–5. **Provider** — seed submodel data, create asset, access policy, usage policy,
   contract definition (unique ids generated per run by the pre-request script).
6. **Catalog** — consumer requests the provider catalog; extracts `offerId`.
7. **Negotiation** — consumer starts an EDR negotiation; extracts `negotiationId`.
8. **Poll negotiation** — self-polls until `FINALIZED` (fails fast on `TERMINATED`).
9. **Query cached EDR** — extracts `transferProcessId`; on the cold-BDRS-cache race
   it automatically re-negotiates once (matching the smoke test).
10. **EDR data address** — extracts the data-plane `endpoint` + `authorization` token.
11. **Fetch** — pulls the asset bytes through the consumer data plane and asserts
    the payload contains the data marker (proves a real end-to-end transfer).

Dynamic variable handling: `offerId → negotiationId → transferProcessId →
edrEndpoint + edrToken` are all set by test scripts; the polling steps (8, 9, 10)
loop via `setNextRequest`.

## Prerequisites

- A running umbrella deployed with the per-participant profile + the image overlay
  (see the [deploy guide](../../../user/common/guides/data-exchange-identity-hub.md)).
- Postman (or `newman`), and a way to reach the ingress hosts. The collection
  handles this for you with the **`ingressIp`** environment variable (the Postman
  equivalent of the smoke test's `INGRESS_IP`):
  - **Default `ingressIp = 127.0.0.1`** — a collection pre-request rewrites each
    request to connect to that IP while sending the real host as a `Host` header
    (ingress-nginx routes by Host). This works out of the box on kind with host
    ports 80/443 mapped, **without any `/etc/hosts` edits**.
  - If you have real DNS or `/etc/hosts` entries for `*.tx.test`, **clear
    `ingressIp`** and requests go to the hostnames directly. The client-side hosts
    are `dataprovider-controlplane`, `dataprovider-submodelserver`,
    `dataprovider-dataplane`, and `dataconsumer-1-controlplane` (`.tx.test`). (The
    IdentityHub hosts `ih-provider` / `ih-consumer1` are resolved pod-side by the
    connector, not by the client.)

## Run it

**Postman app:** import both files, select the **umbrella DCP per-participant
(kind)** environment, then either send the 11 requests top-to-bottom, or use the
**Collection Runner** with a **~2000 ms delay** between requests (so the self-polling
steps have time between attempts).

**newman (CLI):**

```bash
newman run docs/common/api/postman/umbrella-dcp-per-participant.postman_collection.json \
  -e docs/common/api/postman/umbrella-dcp-per-participant.postman_environment.json \
  --delay-request 2000
```

A green run ends with the fetch assertion passing and
`FULL DCP DATA TRANSFER SUCCEEDED` in the console.

> Validated with `newman` 6.x against the per-participant profile on kind
> (`ingressIp=127.0.0.1`): all requests and assertions pass, ending in
> `FULL DCP DATA TRANSFER SUCCEEDED`.

## Use it for the shared or postgres profile

The connector endpoints are the same across profiles; only the provider's DID host
differs. To point the collection at the **shared** or **postgres** profile, change
just one environment variable:

```
providerDid = did:web:identity-hub.tx.test:BPNL00000003AYRE
```

(and you no longer need the `ih-*.tx.test` hosts). Everything else is identical.
