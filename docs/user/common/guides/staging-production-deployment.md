<!--
SPDX-License-Identifier: CC-BY-4.0
Copyright (c) 2026 Contributors to the Eclipse Foundation
-->

# Deploying the umbrella to a staging / production server with HTTPS

This guide walks a developer or DevOps engineer through deploying the Tractus-X
umbrella to a real (non-local) Kubernetes cluster, reachable over **HTTPS** on a
domain you control.

> **Read this first — scope and expectations.** The umbrella chart is built and
> tuned for **end-to-end testing and sandbox** use: by default it runs in-memory
> (no persistence), ships placeholder secrets, and **hardcodes `*.tx.test`
> hostnames** in ~170 places with no single "domain" switch. A staging/production
> deployment is therefore a deliberate **hardening** exercise, not a one-flag
> change. This guide gives a clean, repeatable path and is explicit about every
> decision you must make. If you only need a local HTTPS sandbox, use the
> self-signed flow in [network/tls.md](../../linux/network/tls.md) instead.

You assemble the deployment by layering **your own** values files on top of a base
profile. You never edit the chart in place — where this guide says to edit the TLS
overlay, you edit your **own copy** of it.

---

## 0. What changes vs. the local sandbox

| Concern | Local sandbox (default) | Staging / production (this guide) |
|---|---|---|
| Cluster | kind / minikube | a real cluster, sized for your enabled components |
| Hostnames | `*.tx.test` (fake) | subdomains of a **domain you own**, with real DNS |
| Ingress reachability | host ports 80/443 on localhost | an ingress controller behind a real LoadBalancer |
| TLS | none, or self-signed | cert-manager-issued certs (Let's Encrypt public; internal CA private) |
| Persistence | disabled (in-memory) | enabled (PVCs) for every stateful component you keep |
| Secrets | placeholders (`changeme`, vault token `root`) | real secrets via External Secrets Operator + Vault |
| Components | "everything on" for tests | only the subset you actually need |

You assemble **one** values file of your own, **`values-prod.yaml`**, that:

- enables the components you need (they default to **off**) and disables the rest;
- sets every hostname and cross-service address to your domain (§2);
- configures the cert issuer + per-ingress TLS (§3);
- enables persistence (§4) and points secrets at your manager (§5).

A single file is deliberate: the shipped overlays (`values-tls.yaml`, the adopter
profiles) do **not** all compose via multiple `-f` flags (§7), so keeping your
overrides in one consistent file is the reliable path. Copy snippets from the shipped
overlays as a reference, but own the result.

---

## 1. Prerequisites

- A Kubernetes cluster reachable with `kubectl` (this guide assumes ≥ v1.24).
- `helm` 3.12+ and `kubectl`.
- An **ingress controller** behind a real LoadBalancer. The chart's ingresses
  default to `ingressClassName: nginx`, so [ingress-nginx](https://kubernetes.github.io/ingress-nginx/)
  is the path of least resistance:
  ```bash
  helm upgrade --install ingress-nginx ingress-nginx \
    --repo https://kubernetes.github.io/ingress-nginx \
    --namespace ingress-nginx --create-namespace
  kubectl -n ingress-nginx get svc ingress-nginx-controller -w   # wait for EXTERNAL-IP
  ```
- A **domain you control** (e.g. `dataspace.example.com`) and the ability to create
  DNS records. Point **wildcard DNS** `*.dataspace.example.com` at the ingress
  LoadBalancer (A record to its IP, or CNAME to its hostname) so every subdomain
  resolves with one record.
- Chart dependencies fetched (the `.tgz` archives and `Chart.lock` are git-ignored):
  ```bash
  bash hack/helm-dependencies.bash
  ```

---

## 2. Plan your hostnames (the most important step)

The umbrella has **no** global domain variable. Each component's ingress hostname
**and** every cross-service URL is individually pinned to a `*.tx.test` name in
[charts/umbrella/values.yaml](../../../../charts/umbrella/values.yaml). For a real
deployment you override **all** of them, for the components you enable, in your
`values-prod.yaml`. Two groups:

### 2a. Ingress hostnames

Each enabled component's ingress carries a `hostname:` (or `hosts:`) on `.tx.test`.
Set yours alongside the per-ingress TLS in §3.3.

> **List-replacement gotcha:** several components (notably the connectors) define
> their ingress as a **list** under `ingresses:`. Helm **replaces list entries
> wholesale** — it does not deep-merge list items. So an override must supply the
> **complete** ingress object (`enabled`, `endpoints`, `className`, `tls`,
> `hostname`/annotations), not just `hostname`. Copy the full object from
> [values-tls.yaml](../../../../charts/umbrella/values-tls.yaml) (or values.yaml) and
> edit the host — don't override a single field.

### 2b. Non-ingress cross-service addresses

These are **not** ingress hostnames, so nothing else sets them — you must. Grep
`charts/umbrella/values.yaml` for `tx.test` and override at least these for the
components you enable:

- `wallet.operatorBpn` neighbours: `wallet.identityHub.shared.{didBase,issuerServiceHost,issuerServiceBaseUrl}` and `wallet.stub.*` (the DID/credential-service/STS hosts; see [`_wallet-derive.tpl`](../../../../charts/umbrella/templates/_wallet-derive.tpl) for how DIDs/URLs are derived);
- `portal.portalAddress`, `portal.centralidp.address`, `portal.bpdm.*`, `portal.custodianAddress`, `portal.issuerComponentAddress`;
- Keycloak realm `issuerUri`s (e.g. `…/auth/realms/CX-Central`) on the components that validate tokens (bpndiscovery, discoveryfinder, bpdm, …);
- `bdrs-server-memory.seeding.bpnList[].did` (the BPN→DID directory) if BDRS is enabled;
- the connectors' `dcp`/`sts`/`TX_EDC_IAM_DCP_CREDENTIALSERVICE_URL` and `bdrs.server.url` if you run the data-exchange subset.

> **Acceptance check:** after rendering your config (the mandatory §7a gate),
> `grep -c "tx.test"` over the output must return **0**. Any remaining `tx.test` is a
> host that will not resolve or be certifiable.

---

## 3. TLS with cert-manager

### 3.1 Install cert-manager (decoupled from the umbrella release)

The umbrella *can* install cert-manager itself (it is a conditional dependency and
the TLS overlay sets `cert-manager.enabled: true`). For staging/production, prefer a
**standalone** cert-manager with its own lifecycle, and tell the umbrella **not** to
install a second copy (two controllers fighting over the CRDs is the failure mode):

```bash
helm upgrade --install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --namespace cert-manager --create-namespace \
  --version v1.18.2 --set crds.enabled=true
```

Then in `values-prod.yaml`:

```yaml
cert-manager:
  enabled: false   # cert-manager is managed standalone (above), not by the umbrella
```

(`crds.enabled=true` matches what `values-tls.yaml` uses. The older
`docs/user/linux/network/tls.md` shows the deprecated `installCRDs=true` alias; both
work on v1.18.2, but `crds.enabled` is current.)

### 3.2 Create an issuer

**Public domain — Let's Encrypt (ACME, HTTP-01).** The issuer template
([templates/ca-issuer.yaml](../../../../charts/umbrella/templates/ca-issuer.yaml))
creates an `Issuer` named `umbrella-ca-issuer` when `tls-issuer.acme.enabled: true`.
In your `values-prod.yaml` set:

- `tls-issuer.acme.email` (it ships as `CHANGEME`);
- `tls-issuer.acme.server` — **add** it (the chart omits it and the template defaults
  to Let's Encrypt **production**). For first runs use the staging endpoint to dodge
  [rate limits](https://letsencrypt.org/docs/rate-limits/):
  `https://acme-staging-v02.api.letsencrypt.org/directory`, then switch to production;
- the template also defaults `profile: tlsserver` (a Let's-Encrypt-specific ACME
  profile). For a non-LE / older ACME CA that rejects profiles, add
  `tls-issuer.acme.profile: ""`.

HTTP-01 validation needs **port 80 on your domain publicly reachable** via the same
nginx ingress. Let's Encrypt cannot issue for `.test`/private domains.

**Private staging / corporate CA.** Don't use ACME. Create a self-signed or CA-backed
`ClusterIssuer` (example:
[charts/umbrella/cluster-issuer.yaml](../../../../charts/umbrella/cluster-issuer.yaml))
and set `tls-issuer.acme.enabled: false`.

### 3.3 Apply TLS to your ingresses — two ways

**Manual per-ingress (recommended for staging/production).** In `values-prod.yaml`,
add the issuer annotation and a `tls:` block to **each enabled component's** ingress.
This is the robust path: you control each ingress's `tls` shape, so you avoid the
coalesce conflicts the shared overlay hits once components are enabled (see §7). Note
schemas differ per component — some take a `tls:` map with `secretName`/`hosts`, some a
boolean `tls: true`; copy the shape from
[charts/umbrella/values-tls.yaml](../../../../charts/umbrella/values-tls.yaml) and the
pattern in [network/tls.md](../../linux/network/tls.md). Example (Portal):

```yaml
portal:
  frontend:
    ingress:
      annotations: { cert-manager.io/cluster-issuer: "umbrella-ca-issuer" }
      tls:
        - secretName: "portal.dataspace.example.com-tls"
          hosts: ["portal.dataspace.example.com"]
```

**Convenience overlay (limited).** The shipped `values-tls.yaml` wires the annotation
and `tls:` for the common components in one file. It is handy but **fatally conflicts
with the digital-twin-registry ingress when that component is enabled** (§7), and it
ships `.tx.test` hosts you must replace. Treat it as a reference to copy from, not a
drop-in for an arbitrary component set — and always run the §7a render check.

---

## 4. Persistence

Persistence is **disabled by default**. Enable it for every stateful component you
keep — the PostgreSQL databases, Vault, and any postgres-backed IdentityHub. Each
component exposes its own `persistence:` block under its (Bitnami) `postgresql`
subchart; set `enabled: true`, a `size`, and a `storageClass`:

```yaml
# values-prod.yaml (excerpt)
tx-data-provider:
  dataspace-connector-bundle:
    postgresql:
      primary:
        persistence: { enabled: true, storageClass: "<your-storage-class>", size: 8Gi }
```

(The bundle's own `values.yaml` only shows `enabled`/`size`, but the Bitnami
`postgresql` subchart also honours `storageClass`.) Without persistence, a pod
restart wipes that component's data.

---

## 5. Secrets (do not ship the defaults)

The default values carry **placeholder** secrets (Vault token `root`, `changeme`).
These must never reach staging/production. The umbrella supports three secret modes —
see the dedicated guides:

- **Production** — External Secrets Operator + HashiCorp Vault, via
  [charts/umbrella/values-external-secrets.yaml](../../../../charts/umbrella/values-external-secrets.yaml)
  and the [Secrets Deployment Guide](../secrets/deployment.md) (overview:
  [Secrets Management](../secrets/README.md), [Vault Setup](../secrets/vault-setup.md)).
  **Note:** this overlay hard-`fail`s the render unless `external-secrets.vaultToken`
  (or `external-secrets.vaultAppRoleSecret`) is set — supply it (CLI `--set` or in
  `values-prod.yaml`), and point `vault.server` at your Vault.
- **Development** — ESO with fake secrets (testing only).
- **Legacy** — plain Kubernetes secrets you set yourself (rotate them; never reuse
  the chart defaults).

Override every credential the components you enable consume (DB passwords, Keycloak
client secrets, the connector Vault token, the wallet secrets).

---

## 6. Choose your components and wallet

Every component is **opt-in** (its `<name>.enabled` defaults to `false`), so enable
exactly the ones you need in `values-prod.yaml`. The adopter profiles
([charts/umbrella/values-adopter-data-exchange.yaml](../../../../charts/umbrella/values-adopter-data-exchange.yaml),
etc.) are a useful **reference** for which components + settings a given scenario
needs — copy from them. But **do not layer an adopter profile with the shipped
`values-tls.yaml`**: they fatally conflict on the digital-twin-registry ingress TLS
(§7). Note too that `values-adopter-data-exchange.yaml` deliberately leaves Portal,
CentralIDP, BDRS and the SSI Credential Issuer **off** (adopters bring their own), so
it exposes connector hosts, not `portal.*` — pick a base that matches what you
actually run, and verify with the §8 check against a host you really expose.

For the data-exchange dataspace the wallet is selected by `wallet.mode`:

- `wallet.mode: stub` — the `ssi-dim-wallet-stub` (simplest; **not** a real wallet);
- `wallet.mode: identityHub` — the real IdentityHub + IssuerService. This path
  currently rides an **in-flight upstream stack** (built-from-source images) — read
  [data-exchange-identity-hub.md](./data-exchange-identity-hub.md) before choosing
  it for staging/production.

---

## 7. Validate, then install

> **The shipped sandbox profiles and overlays do not all compose cleanly — validate
> your exact combination first.** Chart components are **opt-in (default off)**, so
> something must enable them. But **layering an adopter/test profile with the shipped
> `values-tls.yaml` fatally conflicts** on the digital-twin-registry ingress TLS
> (Helm "cannot overwrite table with non table … registry.ingress.tls"), and
> `values-external-secrets.yaml` **`fail`s the render** unless
> `external-secrets.vaultToken` (or the AppRole secret) is set. The two robust ways to
> avoid the TLS-overlay conflict are: (a) use the **manual per-ingress TLS** pattern
> (§3.2) in your own `values-prod.yaml` instead of the overlay; or (b) keep the
> overlay only for the components that don't conflict and set the conflicting
> component's `tls` block explicitly. Either way, the render check below is mandatory.

### 7a. Validate the render (mandatory gate)

Run `helm template` on your **exact** `-f` set before installing:

```bash
helm template umbrella charts/umbrella \
  -f values-prod.yaml \
  -f charts/umbrella/values-external-secrets.yaml \
  --set external-secrets.vaultToken=<your-token> > /tmp/render.yaml
echo "exit=$?"                      # must be 0, with NO "Error:" (coalesce *warnings* are OK)
grep -c "tx.test" /tmp/render.yaml  # must be 0 for every host you expose
```

If it errors with `cannot overwrite table with non table … registry.ingress.tls`,
you layered a component-enabling profile with `values-tls.yaml`. Remove the overlay
and use manual per-ingress TLS (§3.2) for that component, or set its `registry.ingress.tls`
block explicitly as a map.

### 7b. Install / upgrade

```bash
helm upgrade --install umbrella charts/umbrella \
  --namespace umbrella --create-namespace --timeout 25m \
  -f values-prod.yaml \
  -f charts/umbrella/values-external-secrets.yaml \
  --set external-secrets.vaultToken=<your-token>
```

- `values-prod.yaml` is your single source of truth: it **enables** the components you
  need (`<name>.enabled: true`), sets your hostnames + cross-service addresses (§2),
  per-ingress TLS (§3.2), persistence (§4), and `cert-manager.enabled: false` (§3.1).
- `external-secrets.vaultToken` (or `vaultAppRoleSecret`) is **required** by the ESO
  overlay — set it on the CLI or in `values-prod.yaml`. Drop the ESO `-f` **and** the
  `--set` if you provision secrets another way (§5).
- Only install once §7a renders cleanly with `grep -c tx.test` == 0.

---

## 8. Verify the deployment

```bash
# 1. all pods Ready
kubectl -n umbrella get pods

# 2. ingresses carry your real hosts + an ADDRESS (the ingress LB)
kubectl -n umbrella get ingress

# 3. certificates issued (READY=True) — not stuck on pending challenges
kubectl -n umbrella get certificate
kubectl -n umbrella get challenges.acme.cert-manager.io 2>/dev/null   # empty once solved

# 4. HTTPS works with a trusted chain — use a host your chosen base actually exposes
#    (for values-adopter-data-exchange.yaml that is a connector, e.g. the control plane)
curl -sSI https://dataprovider-controlplane.dataspace.example.com | head -1
```

A `Certificate` stuck `READY=False` almost always means the HTTP-01 challenge can't
reach your domain on port 80 (DNS not pointing at the LB, or port 80 blocked), or you
used ACME with a non-public domain. `kubectl -n umbrella describe certificate <name>`
shows the reason.

---

## 9. Limitations & hardening checklist

The umbrella is a sandbox baseline. Before calling a deployment "production", also
address:

- [ ] **Hostnames** — every enabled component overridden off `*.tx.test` (the §7a
      render check `grep -c tx.test` returns 0).
- [ ] **TLS** — every public ingress has a `tls:` block + issuer annotation and a
      `Certificate` that is `READY=True`.
- [ ] **cert-manager** — installed exactly once (standalone **or** the umbrella's
      subchart, not both); `cert-manager.crds.keep` governs whether CRDs survive an
      uninstall.
- [ ] **Persistence** — enabled (with a real `storageClass`) for all stateful
      components; PV backups in place.
- [ ] **Secrets** — no chart defaults; real values via ESO/Vault or your manager;
      rotation policy.
- [ ] **Vault durability** — the bundled Vault ships in **dev mode (in-memory)**,
      which ignores storage backends. For durable secrets, disable dev mode and
      handle init/unseal yourself, or use an **external** Vault.
- [ ] **Resource sizing & HA** — requests/limits and replica counts sized for load;
      default profiles are tuned for a single test node.
- [ ] **Exposure** — restrict which ingresses are public; the EDC management APIs and
      Keycloak admin must not be internet-exposed without auth + IP restrictions.
- [ ] **Wallet** — if `wallet.mode: identityHub`, the released images cannot yet
      complete the DCP flow (see the IdentityHub guide); plan around the upstream
      release sequence.

---

## Related documentation

- [Self-signed TLS setup (local)](../../linux/network/tls.md)
- [Secrets Management](../secrets/README.md) · [Deployment Guide](../secrets/deployment.md) · [Vault Setup](../secrets/vault-setup.md) · [External Secrets Operator](./external-secrets.md)
- [Data Exchange with Real IdentityHub](./data-exchange-identity-hub.md)
- [Linux installation guide](../../linux/installation/README.md)
