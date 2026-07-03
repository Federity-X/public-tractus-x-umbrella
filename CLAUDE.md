# CLAUDE.md

> **⚠️ TEMPORARY — DELETE FROM THE REPO BEFORE MERGE.** This file is committed to the
> `feature/BE-241-*` branch **only** to give the coding agent on the 36 GB machine full
> project context (see [docs/HANDOFF-BE-241 in fx-connector-ui](https://github.com/Federity-X/fx-connector-ui/blob/main/docs/HANDOFF-BE-241.md)).
> Once all BE-241 tasks are finished and everything is tested, run `git rm CLAUDE.md`
> (keep only a local, git-ignored copy) — per this repo's own "never commit CLAUDE.md"
> rule in *Working rules* below. It must **not** reach `main`.

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Local repos — ASK for each path; do NOT assume.** This effort spans several **local
> clones** built/modified from source (EDC connector `public-tractusx-edc`, IdentityHub +
> IssuerService `public-tractusx-identityhub`, the `fx-connector-ui` panel, the Portal
> backend for Phase C, and this umbrella). Their filesystem paths differ per machine. At
> the start of a session, **ask the user for the local path of each repo you need before
> running builds** — never assume `~/projects/...`. Full list, remotes, branches, and
> purpose: [fx-connector-ui `docs/HANDOFF-BE-241.md`](https://github.com/Federity-X/fx-connector-ui/blob/main/docs/HANDOFF-BE-241.md).

## What this repository is

Eclipse Tractus-X Umbrella: a **Helm umbrella chart** (plus a small set of supporting
artifacts) that spins up a complete [Catena-X](https://catena-x.net/) dataspace network
from Tractus-X OSS components for **end-to-end testing and sandbox** use. The deliverable
is the chart in [charts/umbrella](charts/umbrella) — there is no application monolith here;
"the code" is mostly Helm templates, values files, and chart composition.

Component versions track an overarching Tractus-X release (currently R25.09, migrating to
R25.12 / R26.06). When you bump a dependency version, also update the component list in
[docs/user/linux/installation/README.md](docs/user/linux/installation/README.md).

## Repository layout (the parts that matter)

- [charts/umbrella](charts/umbrella) — the top-level chart. Its [Chart.yaml](charts/umbrella/Chart.yaml)
  declares every component as a conditional dependency (each gated by `<name>.enabled`).
  Remote deps are pulled from the Tractus-X `charts/dev` channel and other public repos;
  local bundles are referenced via `file://../<bundle>`.
- **Bundle subcharts** (composed into umbrella, each independently installable):
  - `dataspace-connector-bundle` — tractusx-edc connector + PostgreSQL + Vault
  - `digital-twin-bundle` — digital-twin-registry + PostgreSQL
  - `data-persistence-layer-bundle` — simple-data-backend
  - `identity-and-trust-bundle` — wallet implementation: **either** `ssi-dim-wallet-stub`
    **or** `tractusx-identityhub` (+ `tractusx-issuerservice`), never both (see Wallet below)
  - `tx-data-provider` — a **participant** chart, aliased three times in umbrella as
    `tx-data-provider`, `dataconsumerOne`, `dataconsumerTwo` to model provider + 2 consumers
  - `umbrella-infrastructure` — shared infra glue
- [charts/*.yaml](charts) — **CI/test value profiles** (`values-test-*.yaml`), see Profiles below.
- [charts/umbrella/values-*.yaml](charts/umbrella) — **user-facing profiles** (`values-adopter-*.yaml`,
  `values-tls.yaml`, `values-external-secrets.yaml`).
- [simple-data-backend](simple-data-backend) — Spring Boot (Java 21, Maven) in-memory data
  service; the only compiled artifact. Built into a container image and consumed by the
  data-persistence-layer-bundle.
- [init-container](init-container) — Keycloak realm/user seed JSON for centralidp, built into
  an init-container image.
- [hack/helm-dependencies.bash](hack/helm-dependencies.bash) — adds all required helm repos and
  recursively updates chart dependencies. **Run this first** on a fresh checkout.
- [docs](docs) — user/admin guides, architecture decision records, Bruno API collections; internal
  planning docs live in [docs/internal](docs/internal).

## Common commands

```bash
# Prepare chart dependencies (adds helm repos + recursive `helm dependency update`).
# REQUIRED after a fresh clone — see note on .tgz/Chart.lock below.
bash hack/helm-dependencies.bash

# Lint (as CI does it via chart-testing)
ct lint --validate-maintainers=false --target-branch main
# or a single chart:
helm lint charts/umbrella

# Render templates without installing (fastest way to validate template changes)
helm template umbrella charts/umbrella -f charts/values-test-data-exchange.yaml

# Install the default data-exchange profile (run from repo root)
helm install umbrella charts/umbrella --namespace umbrella --create-namespace \
  -f charts/values-test-data-exchange.yaml

# Install a single bundle standalone (mirrors CI install jobs)
cd charts/dataspace-connector-bundle && helm dependency update && \
  helm install dcb --namespace dcb --create-namespace .

# simple-data-backend (Java)
cd simple-data-backend && mvn clean verify        # build + test (matches java-ci.yml)
mvn -Dtest=SimpleDataServiceControllerTest test    # run a single test class

# Test a GitHub workflow locally
act -e .act/pr_event.json pull_request
```

> `*.tgz` chart archives and `Chart.lock` are **git-ignored** (see [.gitignore](.gitignore)).
> They exist locally only after `helm dependency update` / the hack script. A fresh clone has
> no fetched dependencies — always run the hack script before installing or templating.

## Local cluster

README/docs recommend **Minikube** for local runs (Kubernetes >1.24, Helm 3.12+); CI uses
**KinD** with a local registry (`kind-registry:5000`) into which it builds the simple-data-backend,
init-container, and a Jena Fuseki image before installing. Ingress hostnames use the `.tx.test`
domain; the umbrella ships a CoreDNS patch hook
([post-install-coredns-tx-test-patch.yaml](charts/umbrella/templates/post-install-coredns-tx-test-patch.yaml))
so pod-side DNS resolves those hosts. Most components disable persistence and run in-memory by default.

## Wallet abstraction (`wallet.mode`)

The dataspace's Holder Wallet / identity layer is pluggable and is the locus of current feature
work (sig-release #1609). It is driven by `.Values.wallet` in
[charts/umbrella/values.yaml](charts/umbrella/values.yaml):

- `wallet.mode: stub` → `ssi-dim-wallet-stub` (default, simplest)
- `wallet.mode: identityHub` → `tractusx-identityhub` + `tractusx-issuerservice`, with
  `identityHub.topology` of either `shared` (one multi-tenant IdentityHub hosting all
  ParticipantContexts) or `perParticipant` (one IdentityHub per BPN behind its own ingress host)

Key files:
- [_wallet-derive.tpl](charts/umbrella/templates/_wallet-derive.tpl) — single source of truth for
  per-participant DIDs, participant IDs, credential-service/STS/issuer URLs. Other templates call
  these helpers; do not hand-derive these values elsewhere.
- [_wallet-validate.tpl](charts/umbrella/templates/_wallet-validate.tpl) — fails the render if both
  wallet implementations are enabled, or if `wallet.mode` disagrees with the enabled chart.
- [configmap-wallet-mode.yaml](charts/umbrella/templates/configmap-wallet-mode.yaml) — always
  rendered; its purpose is to force the validator to run on every install/upgrade.

When editing wallet wiring, change `_wallet-derive.tpl` and let consumers pick it up; keep the
stub/identityHub mutual exclusion intact.

## Test/CI profiles

[.github/workflows/helm-checks.yaml](.github/workflows/helm-checks.yaml) lints, then installs each
bundle and a series of umbrella profiles on KinD. Each `charts/values-test-*.yaml` maps to a CI
install job — keep them installable in isolation:

- `values-test-data-exchange.yaml` — data exchange with the wallet **stub**
- `values-test-data-exchange-identity-hub.yaml` — data exchange with **shared** IdentityHub
- `values-test-data-exchange-identity-hub-per-participant.yaml` — **per-participant** IdentityHub
- `values-test-iam-init-container-{1,2}.yaml` — centralidp / sharedidp Keycloak
- `values-test-shared-services-{1,2}.yaml` — discovery/semantic/BPDM shared services

`java-ci.yml` runs only on `simple-data-backend/**` changes; chart image builds
(`build-sdb-image.yaml`, `build-init-container.yml`) publish those container images.

## Working rules (this fork)

- **Commit authorship**: commits must carry **only the user's identity**. Do **not** add
  `Co-Authored-By` / co-author trailers or any AI-attribution to commit messages or PR bodies.
- **Never commit** `CLAUDE.md` or work-planning docs (e.g. `docs/internal/plan-*.md`). Keep them
  local; do not stage or include them in commits.
- **Avoid unnecessary fallbacks**, especially for secrets and critical configs. Prefer failing
  fast (explicit error / `fail` in templates) over silently substituting a default value when a
  required secret or critical setting is missing.

## Conventions

- **License headers**: every YAML/template/source file carries the Apache-2.0 SPDX header block
  (code) or CC-BY-4.0 (docs). Match the existing header when adding files. `eclipse-dash.yml` and
  `trufflehog.yml` enforce dependency-license and secret checks in CI.
- **Commits**: this is an Eclipse Foundation project — commits must be **DCO sign-off**ed
  (`git commit -s`) with an author email tied to a signed ECA. See [CONTRIBUTING.md](CONTRIBUTING.md).
- Keep contributions **vendor/cloud-agnostic** and free of company-specific or proprietary config.
