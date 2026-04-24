# How Tractus-X Umbrella Helm Charts Work

**Internal Technical Reference — BE-165**

This document explains the structure of the Tractus-X umbrella Helm chart, how configuration flows into sub-charts, how secrets/infrastructure are wired, and provides a step-by-step checklist for adding a new component (e.g. Identity Hub).

---

## 1. Umbrella Chart Structure

### 1.1 Parent Chart

The umbrella chart lives at `charts/umbrella/`. It is a pure orchestration chart — it contains **no application code**, only:

| File | Purpose |
|------|---------|
| `Chart.yaml` | Declares all sub-chart dependencies with condition flags |
| `values.yaml` | ~1600 lines of defaults; wires hostnames, credentials, and cross-service references |
| `templates/_helpers.tpl` | Shared template helpers (`app.name`, `app.fullname`, `app.chart`) |
| `templates/*.yaml` | Infrastructure templates: SMTP server, BDRS seeding job, portal test-data ConfigMap, ESO/Vault SecretStore & ExternalSecret resources |

### 1.2 Dependencies (from Chart.yaml)

Every dependency has a `condition` flag that defaults to `false` in `values.yaml`, making all components opt-in.

| Name | Alias | Condition Flag | Repository | Version | Source |
|------|-------|---------------|------------|---------|--------|
| `portal` | — | `portal.enabled` | tractusx-dev | 2.6.0 | Remote |
| `centralidp` | — | `centralidp.enabled` | tractusx-dev | 4.2.1 | Remote |
| `sharedidp` | — | `sharedidp.enabled` | tractusx-dev | 4.2.1 | Remote |
| `discoveryfinder` | — | `discoveryfinder.enabled` | tractusx-dev | 0.5.1 | Remote |
| `bpndiscovery` | — | `bpndiscovery.enabled` | tractusx-dev | 0.5.1 | Remote |
| `sdfactory` | `selfdescription` | `selfdescription.enabled` | tractusx-dev | 2.1.35 | Remote |
| `ssi-credential-issuer` | — | `ssi-credential-issuer.enabled` | tractusx-dev | 1.4.0 | Remote |
| `semantic-hub` | — | `semantic-hub.enabled` | tractusx-dev | 0.5.0 | Remote |
| `bpdm` | — | `bpdm.enabled` | tractusx-dev | 6.2.0 | Remote |
| `tx-data-provider` | `dataconsumerOne` | `dataconsumerOne.enabled` | `file://../tx-data-provider` | 0.4.6 | Local |
| `tx-data-provider` | — | `tx-data-provider.enabled` | `file://../tx-data-provider` | 0.4.6 | Local |
| `tx-data-provider` | `dataconsumerTwo` | `dataconsumerTwo.enabled` | `file://../tx-data-provider` | 0.4.6 | Local |
| `pgadmin4` | — | `pgadmin4.enabled` | helm.runix.net | 1.25.x | Remote |
| `bdrs-server-memory` | — | `bdrs-server-memory.enabled` | tractusx-dev | 0.5.7 | Remote |
| `identity-and-trust-bundle` | — | `identity-and-trust-bundle.enabled` | `file://../identity-and-trust-bundle` | 1.1.3 | Local |
| `opentelemetry-collector` | — | `opentelemetry-collector.enabled` | OTEL | 0.126.0 | Remote |
| `jaeger` | — | `jaeger.enabled` | jaegertracing | 3.0.7 | Remote |
| `prometheus` | — | `prometheus.enabled` | prometheus-community | 27.1.0 | Remote |
| `loki` | — | `loki.enabled` | grafana | 6.27.0 | Remote |
| `grafana` | — | `grafana.enabled` | grafana | 8.10.1 | Remote |
| `cert-manager` | — | `cert-manager.enabled` | jetstack | v1.18.2 | Remote |

**Key patterns:**
- **Alias usage**: `sdfactory` → alias `selfdescription`; `tx-data-provider` is reused 3× with aliases `dataconsumerOne` and `dataconsumerTwo`.
- **Local vs Remote**: Bundle charts use `file://` references; product charts use the Tractus-X Helm registry.
- **Condition flags** always follow the pattern `<name-or-alias>.enabled`.

### 1.3 Local Bundle Charts

Four reusable capability bundles sit in `charts/` alongside the umbrella:

| Bundle | Path | Composes |
|--------|------|----------|
| `dataspace-connector-bundle` | `charts/dataspace-connector-bundle/` | tractusx-connector (0.11.2), postgresql (15.2.1), vault (0.27.0) |
| `digital-twin-bundle` | `charts/digital-twin-bundle/` | digital-twin-registry, postgresql |
| `data-persistence-layer-bundle` | `charts/data-persistence-layer-bundle/` | simple-data-backend |
| `identity-and-trust-bundle` | `charts/identity-and-trust-bundle/` | ssi-dim-wallet-stub, postgresql |

The `tx-data-provider` chart (`charts/tx-data-provider/`) composes the first three bundles into a complete dataspace participant, and adds post-install hooks for vault setup and test-data seeding.

---

## 2. Configuration Flow

### 2.1 How Values Cascade

Helm's sub-chart value injection works as follows:

```
values.yaml (umbrella)
  ├── portal:           → passed to portal sub-chart as its .Values
  ├── centralidp:       → passed to centralidp sub-chart
  ├── dataconsumerOne:  → passed to tx-data-provider (aliased)
  │     └── dataspace-connector-bundle:  → nested sub-sub-chart values
  │           └── tractusx-connector:    → nested sub-sub-sub-chart values
  └── ...
```

Configuration is **hierarchical** — umbrella values define the top key matching the dependency name (or alias), and all nested keys are passed down verbatim.

### 2.2 Enable/Disable Pattern

Every component defaults to disabled:

```yaml
# In charts/umbrella/values.yaml
portal:
  enabled: false       # ← condition flag; matches Chart.yaml condition
  replicaCount: 1      # ← passed to sub-chart when enabled
  postgresql:
    nameOverride: "portal-backend-postgresql"
    ...
```

### 2.3 Cross-Service Wiring

Services reference each other through **hardcoded `*.tx.test` hostnames** in values.yaml. Example showing how the portal knows about other services:

```yaml
portal:
  centralidp:
    address: "http://centralidp.tx.test"
  bpdm:
    poolAddress: "http://business-partners.tx.test"
  custodianAddress: "http://ssi-dim-wallet-stub.tx.test"
  issuerComponentAddress: "http://ssi-credential-issuer.tx.test"
```

All services authenticate against CentralIDP at `http://centralidp.tx.test/auth/realms/CX-Central` using pre-configured service account client IDs and secrets.

### 2.4 EDC Connector Identity Wiring

Each EDC instance is configured with:
1. **Participant ID (BPN)** — e.g., `BPNL00000003AZQP`
2. **DID** — `did:web:ssi-dim-wallet-stub.tx.test:<BPN>`
3. **Trusted issuers** — the operator DID `did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003CRHK`
4. **STS/OAuth endpoints** — pointing to the SSI DIM Wallet Stub
5. **Vault URL** — per-instance HashiCorp Vault for keys and secrets

Example for dataconsumerOne:

```yaml
dataconsumerOne:
  enabled: false
  dataspace-connector-bundle:
    tractusx-connector:
      participant:
        id: BPNL00000003AZQP
      iatp:
        id: did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003AZQP
        trustedIssuers:
          - did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003CRHK
        sts:
          dim:
            url: http://ssi-dim-wallet-stub.tx.test/api/sts
          oauth:
            token_url: http://ssi-dim-wallet-stub.tx.test/oauth/token
            client:
              id: BPNL00000003AZQP
              secret_alias: edc-wallet-secret
```

### 2.5 Profile Values Files

Pre-built values files enable specific subsets of the stack:

| File | What it enables |
|------|----------------|
| `values-test-data-exchange.yaml` | EDC provider + consumers, Wallet, BDRS (data exchange testing) |
| `values-test-iam-init-container-1.yaml` | CentralIDP + SharedIDP (IAM phase 1) |
| `values-test-iam-init-container-2.yaml` | CentralIDP + SharedIDP (IAM phase 2) |
| `values-test-shared-services-1.yaml` | Portal, IAM, BPDM |
| `values-test-shared-services-2.yaml` | + Discovery, Semantic Hub |
| `values-adopter-data-exchange.yaml` | Production-style data exchange |
| `values-adopter-portal.yaml` | Production-style portal |
| `values-tls.yaml` | TLS overlay (cert-manager) |
| `values-external-secrets.yaml` | External Secrets Operator + Vault integration |

Layering: `helm install umbrella charts/umbrella -f charts/values-test-data-exchange.yaml -f charts/umbrella/values-tls.yaml`

---

## 3. Secrets & Shared Infrastructure

### 3.1 Per-EDC HashiCorp Vault

Each EDC participant deploys its own Vault sub-chart. A Helm **post-install hook** (`post-install-vault-setup.yaml` in `tx-data-provider/templates/`) seeds the Vault with:

| Secret Path | Content |
|-------------|---------|
| `secret/data/edc-wallet-secret` | IATP client secret (for SSI Wallet authentication) |
| `secret/data/tokenSignerPublicKey` | RSA public key (PEM) |
| `secret/data/tokenSignerPrivateKey` | RSA private key (PEM) |
| `secret/data/tokenEncryptionAesKey` | AES symmetric key |

The hook uses `wget` from an Alpine container to POST secrets to the Vault HTTP API at the per-instance URL (e.g., `http://<release>-edc-dataprovider-vault:8200`).

Additional secrets are defined in `tx-data-provider/values.yaml` under `secrets:` and written to Vault as a loop:

```yaml
secrets:
  edc-wallet-secret: changeme
```

### 3.2 External Secrets Operator (ESO) Integration

For production-like deployments, the umbrella supports ESO + Vault:

**Templates:**
- `vault-secretstore.yaml` — Creates a `SecretStore` CR pointing to Vault (supports `token` or `appRole` auth)
- `vault-external-secrets.yaml` — Iterates `externalSecrets` from values, creates `ExternalSecret` CRs per secret group
- `fake-secretstore.yaml` / `fake-external-secrets.yaml` — Stands in when Vault is disabled but ESO is enabled

**Activation** — via `values-external-secrets.yaml`:

```yaml
external-secrets:
  enabled: true
  vaultToken: ""           # Or vaultAppRoleSecret for appRole auth
vault:
  enabled: true
  server: "http://umbrella-infra-vault:8200"
  path: "secret"
  version: "v2"
  auth:
    method: "token"        # or "appRole"
    tokenSecret:
      name: "vault-token"
      key: "token"
```

**Secret definitions** — the `externalSecrets` map in values defines which Vault paths to sync:

```yaml
externalSecrets:
  umbrella-centralidp-postgresql:
    postgres-password: dbpasswordcentralidp
    password: dbpasswordcentralidp
  umbrella-centralidp-base-service-accounts:
    sa-cl1-reg-2: "changeme1"
    ...
```

The `dataseeding/vault-secrets-setup.py` script can bulk-load these secrets into Vault using the HTTP API.

### 3.3 Keycloak Realm Seeding

CentralIDP uses an **init container** (`umbrella-init-container:2.3.0-init`) that provisions the `CX-Central` realm with:
- Client registrations for all services
- 19 service accounts (`sa-cl1-reg-2` through `sa-cl25-cx-3`)
- 16 test EDC service accounts (`satest01`–`satest16`) with BPN mappings
- Redirect URIs pointing to `*.tx.test` services

Configured under `centralidp.realmSeeding` in values.yaml.

### 3.4 Ingress & Networking

All services share:
- **Ingress class**: `nginx`
- **Domain convention**: `*.tx.test` (non-routable; requires `/etc/hosts` or DNS config)
- **CORS**: Enabled with origin `http://*.tx.test`
- **TLS**: Disabled by default; enabled via `values-tls.yaml` + cert-manager

### 3.5 BDRS Seeding

The `post-install-bdrs-setup.yaml` template in the umbrella chart creates a post-install Job that seeds BPN↔DID mappings into the BDRS server via its management API:

```yaml
bdrs-server-memory:
  seeding:
    enabled: true
    bpnList:
      - bpn: "BPNL00000003CRHK"
        did: "did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003CRHK"
      - bpn: "BPNL00000003AZQP"
        did: "did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003AZQP"
      ...
```

---

## 4. Current Identity Architecture (What Identity Hub Would Replace/Extend)

Today, identity is handled by three components:

| Component | Role |
|-----------|------|
| **SSI DIM Wallet Stub** | Issues DIDs, Verifiable Credentials, handles IATP/STS for EDC connectors. **This is a stub/mock** — not production-grade. |
| **CentralIDP (Keycloak)** | OAuth2/OIDC for human users and service accounts accessing Portal, BPDM, Discovery, etc. |
| **BDRS Server** | In-memory BPN↔DID resolution for credential verification during data exchange. |

**EDC connectors** authenticate to each other via the SSI Wallet Stub using the IATP/DCP protocol (Verifiable Presentations). They do NOT use Keycloak for connector-to-connector auth.

**Identity Hub** would **replace the SSI DIM Wallet Stub** as the production wallet implementation. In the Tractus-X ecosystem it is shipped by **`eclipse-tractusx/tractusx-identityhub`** as four Helm charts — `tractusx-identityhub`, `tractusx-identityhub-memory`, `tractusx-issuerservice`, `tractusx-issuerservice-memory` — providing:
- Real DID management
- Verifiable Credential issuance and storage
- IATP Secure Token Service
- Credential verification

---

## 5. Checklist: Adding a New Component to the Umbrella Chart

Use this checklist when integrating Identity Hub (or any new component). Concrete values shown here use **`eclipse-tractusx/tractusx-identityhub`** chart names.

### Step 1: Add Dependency in Chart.yaml

```yaml
# charts/umbrella/Chart.yaml
dependencies:
  # ... existing deps ...
  - name: tractusx-identityhub-memory          # or tractusx-identityhub for prod (Postgres + Vault)
    condition: tractusx-identityhub-memory.enabled
    repository: file://../../../tractusx-identityhub/charts/tractusx-identityhub-memory
    version: 0.2.0                              # matches gradle.properties in that repo
    alias: identity-hub                         # map to a shorter values key
```

**Decision**: Remote (published chart) or Local (`file://`)?
- Use **local** during active development (clone `eclipse-tractusx/tractusx-identityhub` alongside the umbrella repo and reference `charts/tractusx-identityhub-memory`)
- Use **remote** once Tractus-X publishes the chart to a Helm repository (not published at time of writing — see that repo's README for status)

### Step 2: Add Values Section in values.yaml

```yaml
# charts/umbrella/values.yaml

identity-hub:
  enabled: false                                # Default disabled (opt-in)
  
  # Pass config to the sub-chart's own values here:
  someSubChartKey:
    host: "identity-hub.tx.test"
    
  # Wire to CentralIDP for OAuth:
  centralidp:
    address: "http://centralidp.tx.test"
    realm: "CX-Central"
    
  # Wire to EDC connectors (if replacing wallet stub):
  sts:
    url: "http://identity-hub.tx.test/api/sts"
    
  # Database if needed:
  postgresql:
    nameOverride: "identity-hub-postgresql"
    auth:
      password: "dbpasswordidentityhub"
      postgresPassword: "dbpasswordidentityhub"
    primary:
      persistence:
        enabled: false                          # In-memory for testing
        
  # Ingress:
  ingress:
    enabled: true
    className: "nginx"
    hosts:
      - host: "identity-hub.tx.test"
        paths:
          - path: "/"
            pathType: "Prefix"
```

### Step 3: Update Cross-Service References

If Identity Hub replaces the SSI DIM Wallet Stub, update all references in `values.yaml`:

```yaml
# EDC connectors — update IATP STS/OAuth endpoints:
dataconsumerOne:
  dataspace-connector-bundle:
    tractusx-connector:
      iatp:
        sts:
          dim:
            url: http://identity-hub.tx.test/api/sts        # ← was ssi-dim-wallet-stub
          oauth:
            token_url: http://identity-hub.tx.test/oauth/token

# Portal — update DIM wrapper:
portal:
  custodianAddress: "http://identity-hub.tx.test"
  dimWrapper:
    baseAddress: "http://identity-hub.tx.test"
    tokenAddress: "http://identity-hub.tx.test/oauth/token"

# Credential Issuer:
ssi-credential-issuer:
  walletAddress: "http://identity-hub.tx.test"
  walletTokenAddress: "http://identity-hub.tx.test/oauth/token"
```

### Step 4: Wire Secrets

**Option A: Per-instance Vault (like EDC pattern)**
- Create a post-install hook template that seeds secrets to Identity Hub's Vault
- Pattern: see `charts/tx-data-provider/templates/post-install-vault-setup.yaml`

**Option B: External Secrets Operator**
- Add entries to the `externalSecrets` map in `values-external-secrets.yaml`:

```yaml
externalSecrets:
  umbrella-identity-hub:
    db-password: "dbpasswordidentityhub"
    signing-key: "<key-value>"
```

- Add corresponding entries to `dataseeding/vault-secrets.yaml`:

```yaml
externalSecrets:
  umbrella-identity-hub:
    db-password: dbpasswordidentityhub
    signing-key: "<key-value>"
```

**Option C: Keycloak client registration**
If Identity Hub needs its own Keycloak client, add to `centralidp.realmSeeding`:

```yaml
centralidp:
  realmSeeding:
    clients:
      identityHub:
        clientSecret: "changeme"
        redirects:
          - http://identity-hub.tx.test/*
    serviceAccounts:
      clientSecrets:
        - clientId: "sa-cl-identity-hub"
          clientSecret: "changeme"
```

### Step 5: Add DNS / Ingress Entry

Add `identity-hub.tx.test` to:
1. The ingress configuration in the values section (Step 2)
2. Documentation: `docs/user/mac/with-docker-desktop.md` (and linux/windows equivalents) — add to the `/etc/hosts` list
3. The "Available Services" list in network setup docs

### Step 6: Add BDRS Seeding (if needed)

If Identity Hub serves DIDs directly (and replaces the wallet stub's BPN directory), the BDRS seeding may need updating or the EDC `bdrs.server.url` setting needs to point to Identity Hub instead.

### Step 7: Add to Profile Values Files

Enable the component in relevant profile files:

```yaml
# charts/values-test-data-exchange.yaml
identity-hub:
  enabled: true
```

### Step 8: Update Helm Dependencies Script

If using a new Helm repository, add it to `hack/helm-dependencies.bash`:

```bash
if ! helm repo list | grep -q "^new-repo-name[[:space:]]"; then
  echo "Adding new-repo-name repository..."
  helm repo add new-repo-name https://new-repo-url
fi
```

If it's a local chart, add the directory to the dependency update loop.

### Step 9: Update docs/user/linux/installation/README.md

The `Chart.yaml` header comment states: *"when adding or updating versions of dependencies, also update list under /docs/user/linux/installation/README.md"*

### Step 10: Test

```bash
# Update dependencies
bash hack/helm-dependencies.bash

# Install with the new component
helm install umbrella charts/umbrella \
  --set identity-hub.enabled=true \
  --set identity-and-trust-bundle.enabled=true \
  --set bdrs-server-memory.enabled=true \
  --set tx-data-provider.enabled=true \
  --set dataconsumerOne.enabled=true \
  --namespace umbrella --create-namespace \
  --timeout 15m

# Verify
kubectl get pods -n umbrella | grep identity-hub
curl http://identity-hub.tx.test/health
```

---

## 6. Risks & Caveats

| Risk | Mitigation |
|------|-----------|
| Chart structure changes between Tractus-X releases | Pin versions in Chart.yaml; review release notes before upgrading |
| Helper templates in `hack/helm-dependencies.bash` add hidden behavior | Script only manages repos and `helm dependency update` ordering — no chart logic |
| The SSI DIM Wallet Stub is deeply wired (EDC IATP, Portal DIM, Credential Issuer, BDRS) | All reference points documented in Step 3 above; systematic find-and-replace needed |
| `tx-data-provider` post-install hooks assume specific Vault layout | If Identity Hub changes the secret paths, update `vault-edc-configmap.yaml` and `post-install-vault-setup.yaml` |
| Keycloak realm seeding is image-based (init container) | Adding new clients/service accounts requires either updating the init container image or using `extraServiceAccounts` config |

---

## 7. Key File Reference

| File | What to look at |
|------|----------------|
| `charts/umbrella/Chart.yaml` | All dependency declarations |
| `charts/umbrella/values.yaml` | All configuration; cross-service wiring |
| `charts/umbrella/templates/_helpers.tpl` | Shared name/label helpers |
| `charts/umbrella/templates/post-install-bdrs-setup.yaml` | BDRS seeding hook |
| `charts/umbrella/templates/vault-secretstore.yaml` | ESO SecretStore template |
| `charts/umbrella/templates/vault-external-secrets.yaml` | ESO ExternalSecret template |
| `charts/umbrella/values-external-secrets.yaml` | ESO + Vault configuration overlay |
| `charts/tx-data-provider/templates/post-install-vault-setup.yaml` | Per-EDC Vault seeding hook |
| `charts/tx-data-provider/templates/post-install-job-upload-testdata.yaml` | Test data upload hook |
| `charts/identity-and-trust-bundle/values.yaml` | SSI DIM Wallet Stub config (what Identity Hub replaces) |
| `hack/helm-dependencies.bash` | Repo management and dependency update script |
| `dataseeding/vault-secrets.yaml` | All secrets for Vault pre-loading |
| `dataseeding/vault-secrets-setup.py` | Vault bulk-seeding script |

---

*Document for BE-165 — Based on tractus-x-umbrella v3.15.6 analysis (aligned with Tractus-X Release 25.12)*
