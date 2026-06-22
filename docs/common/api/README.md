# API Requests for Data Exchange

This document provides information about API requests for the Data Exchange.

## Bruno

There is a Bruno collection containing all the data exchange flow between Alice and Bob:

- [Umbrella-bru](./bruno/Umbrella-bru) - Bruno collection in `.bru` format

## Postman

There is a single, self-contained Postman collection that runs the full DCP data
exchange (catalog → contract negotiation → transfer → fetch) end-to-end against the
IdentityHub **per-participant** profile, with dynamic variable threading and
self-polling:

- [umbrella-dcp-per-participant.postman_collection.json](./postman/umbrella-dcp-per-participant.postman_collection.json) — see the [Postman README](./postman/README.md) for usage.

## Curl

There is a guide containing step by step tutorial on how to exchange data between [provider](../user/guides/data-exchange/provide-data.md) and [consumer](../user/guides/data-exchange/consume-data.md), using the console.

## NOTICE

This work is licensed under the [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0).

* SPDX-License-Identifier: Apache-2.0
* SPDX-FileCopyrightText: 2025 Contributors to the Eclipse Foundation
* Source URL: <https://github.com/eclipse-tractusx/tractus-x-umbrella>
