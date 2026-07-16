<!--
  Copyright (c) 2026 Contributors to the Eclipse Foundation
  SPDX-License-Identifier: CC-BY-4.0
  INTERNAL runbook — do NOT commit to main (per repo working rules). Local reference only.
-->

# BE-293 full rebuild runbook — durable IdentityHub + Portal onboarding + credential callback

Reproducible, from-scratch bring-up of the **combined dataspace** (connectors + Portal) on a
**durable Postgres IdentityHub**, with the **`portal-credential-callback` observer extension** wired
so a Portal onboarding advances its credential checklist steps when IdentityHub issues the holder's
BPN/Membership credentials.

> Status: verified end-to-end on 2026-07-15 (kind cluster `umbrella-1609`, macOS/arm64, Docker VM 31 GiB).
> This is a SANDBOX/DEMO runbook — it rides in-flight forked images and (for the onboarding demo) a few
> documented DB bridges around a local-sandbox DID-resolution limitation (see §7). Not production.

---

## 0. What gets deployed

- **Connectors**: `tx-data-provider` + `dataconsumerOne` + `dataconsumerTwo` (tractusx-edc 0.13.0-SNAPSHOT / EDC 0.17.0), each with a **persistent (PVC) Postgres**.
- **Wallet**: **`tractusx-identityhub` (Postgres-backed)** + `tractusx-issuerservice` — shared multi-tenant IH on `identity-hub.tx.test` (admin API on `identity-hub-admin.tx.test`). SQL-backed → wallets/credentials survive a pod restart.
- **DTR** (`:be241`), **simple-data-backend** (`:jpa`), **BDRS (in-memory)**.
- **Portal** (forked `:be293` images carrying the wallet integration) + **CentralIDP/SharedIDP** (Keycloak) + **BPDM** + discovery services.
- The IH runs the **`portal-credential-callback`** extension (built into `docker-identityhub:latest`).

## 1. Prerequisites (repos / branches / tooling)

Ask per machine; on the reference box:

| Repo | Path | Branch |
|---|---|---|
| umbrella | `/Users/tvs-indetechs/public-tractus-x-umbrella` | `feature/BE-241-admin-panel-per-participant-plus` |
| identityhub | `/Users/tvs-indetechs/IdeaProjects/public-tractusx-identityhub` | `feat/holder-credential-request-status-callback` (on top of Federity-X `fix/321-322-dcp-e2e-collections-and-charts`) |
| tractusx-edc | `/Users/tvs-indetechs/IdeaProjects/public-tractusx-edc` | `main` (== upstream) |
| DTR | `/Users/tvs-indetechs/IdeaProjects/public-sldt-digital-twin-registry` | `feat/shell-descriptors-sort-direction` |
| portal-backend (source ref only) | `/Users/tvs-indetechs/projects/portal-backend` | — |

- JDK 21 for the Gradle builds: `export JAVA_HOME=/Users/tvs-indetechs/Library/Java/JavaVirtualMachines/ms-21.0.8/Contents/Home` (default `java` is 25).
- Docker Desktop VM ~24 GiB+ (reference: 31 GiB). `helm`, `kubectl`, `kind`.
- The forked Portal `:be293` images must already be built/present (from the portal-backend fork): `tractusx/portal-{registration,administration,processes-worker,migrations}-service:be293` / `tractusx/portal-*:be293`.

## 2. Build the 6 source images (JDK 21)

```bash
export JAVA_HOME=/Users/tvs-indetechs/Library/Java/JavaVirtualMachines/ms-21.0.8/Contents/Home

# (a) Connector CP + DP  -> tractusx/edc-*-hashicorp-vault:0.13.0-SNAPSHOT
cd <edc>
./gradlew -x test :edc-controlplane:edc-controlplane-postgresql-hashicorp-vault:dockerize \
                  :edc-dataplane:edc-dataplane-hashicorp-vault:dockerize
docker tag edc-controlplane-postgresql-hashicorp-vault:0.13.0-SNAPSHOT tractusx/edc-controlplane-postgresql-hashicorp-vault:0.13.0-SNAPSHOT
docker tag edc-dataplane-hashicorp-vault:0.13.0-SNAPSHOT             tractusx/edc-dataplane-hashicorp-vault:0.13.0-SNAPSHOT

# (b) IdentityHub (+ portal-credential-callback ext) + IssuerService
#     -> docker-identityhub[-memory]:latest, docker-issuerservice:latest
cd <identityhub>            # branch feat/holder-credential-request-status-callback
./gradlew -x test :runtimes:identityhub:dockerize :runtimes:identityhub-memory:dockerize :runtimes:issuerservice:dockerize
docker tag identityhub:latest        docker-identityhub:latest          # POSTGRES IH (used here)
docker tag identityhub-memory:latest docker-identityhub-memory:latest
docker tag issuerservice:latest      docker-issuerservice:latest
# sanity: the extension must be in the jar
docker run --rm --entrypoint sh docker-identityhub:latest -c 'unzip -l /app/identityhub.jar | grep -c PortalCredentialCallback'   # >0

# (c) DTR / (d) submodel backend / (e) init-container
cd <dtr>            && docker build -f backend/Dockerfile -t tractusx/sldt-digital-twin-registry:be241 .
cd <umbrella>/simple-data-backend && docker build -t tractusx/simple-data-backend:jpa .
cd <umbrella>/init-container       && docker build -t umbrella-init-container:be241 .
```

## 3. kind cluster + ingress + coredns + drop the strict admission webhook

```bash
cat > /tmp/kind-config.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: umbrella-1609
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - { containerPort: 80,  hostPort: 80,  protocol: TCP }
      - { containerPort: 443, hostPort: 443, protocol: TCP }
EOF
kind create cluster --name umbrella-1609 --config /tmp/kind-config.yaml
kubectl wait --for=condition=ready node --all --timeout=120s     # node must be Ready before applying ingress
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait -n ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=180s

# REQUIRED: the newer ingress-nginx admission webhook rejects the umbrella's regex `Prefix`
# ingress paths (e.g. /bpndiscovery(/|$)(.*)). Drop it (nginx routes them fine at runtime).
kubectl delete validatingwebhookconfiguration ingress-nginx-admission
```

Browser access (for §6 onboarding): add to `/etc/hosts` (sudo) then flush DNS:
```
127.0.0.1 portal.tx.test centralidp.tx.test sharedidp.tx.test portal-backend.tx.test
```

## 4. Chart deps + load images

```bash
cd <umbrella>
bash hack/helm-dependencies.bash        # fetch/repackage chart deps (also applies the BE-293 portal chart patch)

kind load docker-image \
  docker-identityhub:latest docker-identityhub-memory:latest docker-issuerservice:latest \
  tractusx/edc-controlplane-postgresql-hashicorp-vault:0.13.0-SNAPSHOT \
  tractusx/edc-dataplane-hashicorp-vault:0.13.0-SNAPSHOT \
  tractusx/sldt-digital-twin-registry:be241 tractusx/simple-data-backend:jpa umbrella-init-container:be241 \
  tractusx/portal-registration-service:be293 tractusx/portal-administration-service:be293 \
  tractusx/portal-processes-worker:be293 tractusx/portal-migrations:be293 \
  --name umbrella-1609
```

> If you edit an umbrella SUBCHART template (e.g. `charts/tx-data-provider/templates/*`), re-package it into the
> umbrella BEFORE templating/installing: `helm package charts/tx-data-provider -d charts/umbrella/charts/`.
> A plain source edit is invisible until repackaged. Do NOT leave a `charts/umbrella/tmpcharts-*` dir behind
> (an interrupted `helm dependency update`) — helm packs it into the release Secret and blows past the 1 MB limit.

## 5. Phase 1 — connector stack on the durable Postgres IdentityHub

```bash
cd <umbrella>
helm install umbrella charts/umbrella \
  -f charts/values-test-data-exchange-identity-hub.yaml \
  -f charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml \
  -f charts/values-test-data-exchange-identity-hub-postgres.yaml \
  -f charts/values-connector-persistence.yaml \
  -f charts/values-callback-activation.yaml \
  --namespace umbrella --create-namespace --timeout 25m
```

Overlays: `-postgres` switches the IH to the SQL-backed variant (same `identity-hub.tx.test` ingress; admin
API on `identity-hub-admin.tx.test`); `values-connector-persistence.yaml` gives each connector Postgres a 5 Gi
PVC + widens the control-plane probes; `values-callback-activation.yaml` **pins** `EDC_IH_API_SUPERUSER_KEY`
(so the key is stable/known across restarts — it MUST be set on first IH boot) and configures the callback env.

**Verify:**
```bash
kubectl get pods -n umbrella | grep -vE 'Running|Completed'          # only transient startup races expected
INGRESS_IP=127.0.0.1 ./hack/dcp-data-transfer-smoke.sh               # => FULL DCP DATA TRANSFER SUCCEEDED
# credentials seeded (PLAIN participantContextId in the URL, not base64; port 8082 on the postgres IH):
#   GET http://identity-hub-admin.tx.test/api/identity/v1alpha/participants/provider-bpnl00000003ayre/credentials
#   -> 4 credentials, state 500 (ISSUED)
```

## 6. Phase 2 — Portal + callback activation

```bash
cd <umbrella>
helm upgrade umbrella charts/umbrella \
  -f charts/values-test-data-exchange-identity-hub.yaml \
  -f charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml \
  -f charts/values-test-data-exchange-identity-hub-postgres.yaml \
  -f charts/values-connector-persistence.yaml \
  -f charts/values-callback-activation.yaml \
  -f charts/umbrella/values-combined-portal-additions.yaml \
  --set centralidp.realmSeeding.initContainer.image.name=umbrella-init-container:be241 \
  --set centralidp.realmSeeding.initContainer.image.pullPolicy=Never \
  --namespace umbrella --timeout 25m
```

The connector Postgres PVCs persist across this upgrade, so the EDC schema is NOT wiped. If DCP breaks after an
upgrade with `relation "edc_contract_negotiation" does not exist`, the connector DBs were recreated empty —
`kubectl rollout restart deploy -l ...edc-controlplane/-dataplane` to re-provision the schema.

**Verify the extension is ACTIVE and delivering:**
```bash
IH=$(kubectl get po -n umbrella -o name | grep identity-hub-postgres- | grep -v postgresql | head -1)
kubectl logs -n umbrella $IH | sed -E 's/\x1b\[[0-9;]*m//g' | grep -E 'started \(scanning|Delivered Portal callback'
# => "Portal Credential Callback Extension started (scanning every 10s)"
# => "Delivered Portal callback: bpn=... type=MembershipCredential status=SUCCESSFUL" for the seeded holders
#    (Portal returns 404 for seeded BPNs — correct: they have no SUBMITTED onboarding application.)
```

## 7. Onboarding demo (real participant, browser-driven) + the callback closing the loop

Creates a NEW participant via the Portal and shows the callback advancing its credential checklist steps.
Onboarding config used below (from `charts/umbrella/values-combined-portal-additions.yaml` + the CX-Central realm):
issuer DID `did:web:issuer-service.tx.test:BPNL00000003CRHK`, issuer pid `issuer-bpnl00000003crhk`,
cred-defs `tx-bpncredential` / `tx-membershipcredential`, callback client **`sa-cl24-01`** (the ONLY base SA with
BOTH `update_application_bpn_credential` + `update_application_membership_credential` Cl2-CX-Portal roles),
secret `changeme`.

1. **Invite** a company (operator): reset cx-operator pw (master admin `admin/adminconsolepwcentralidp` →
   reset `cx-operator` in CX-Central to `Testpass1!`), operator token (`Cl2-CX-Portal` password grant), then
   `POST portal-backend.tx.test/api/administration/invitation {organisationName, firstName, lastName, email}`
   → `{applicationId, companyId}`. The processes-worker (cron, every 5 min) creates the `idp1` shared realm +
   the invited user; set that user's password via the **sharedidp** admin (`admin/adminconsolepwsharedidp`,
   realm `idp1`; password policy: length ≥ 15, e.g. `Cx-Onboard-2026!`), clear requiredActions, emailVerified.
2. **Browser** (`http://portal.tx.test/registration`): click the company IdP button (labelled by the company
   name = the `idp1` broker), log in as the invited user, complete the form, **Submit** → application SUBMITTED.
3. **Approve** (operator): `POST .../registration/applications/{appId}/approve` then assign a BPN
   `POST .../registration/application/{appId}/{BPN}/bpn` (e.g. `BPNL00000042ONBD`). REGISTRATION_VERIFICATION +
   BUSINESS_PARTNER_NUMBER → DONE. The worker then creates+activates the wallet on the IH (`POST identity-hub-admin.tx.test/api/identity/v1alpha/participants` → 200, `/state` → 204).
4. **Credentials → callback**: the worker requests BPN + Membership credentials → IssuerService issues → the
   holder pulls (state 500) → the `portal-credential-callback` extension posts the Portal issuer callback →
   `BPNL_CREDENTIAL` + `MEMBERSHIP_CREDENTIAL` checklist steps → DONE.

### ⚠ Local-sandbox limitation + the bridges it forces (§7 step 3–4)
`VALIDATE_DID_DOCUMENT` resolves the new `did:web:identity-hub.tx.test:...` via the PUBLIC Universal Resolver
`dev.uniresolver.io` (`APPLICATIONCHECKLIST__DIM__UNIVERSALRESOLVERADDRESS`), which **cannot reach a local
`.tx.test` did:web** → 404 → the step FAILS (the wallet + DID are functionally created on the IH). No local
universal resolver ships in the umbrella, so the Portal's own credential-request chain stalls there. To
demonstrate the callback past it, bridge in the Portal DB (db `postgres`, user `portal`, pw secret
`portal-postgres/portal-password`): mark `VALIDATE_DID_DOCUMENT` DONE, set the two credential checklist entries
IN_PROGRESS, insert `AWAIT_{BPN,MEMBERSHIP}_CREDENTIAL_RESPONSE` process steps, and drive the credential
requests directly on the IH (IS holder registration `POST issuer-service-admin.tx.test/api/admin/v1alpha/participants/issuer-bpnl00000003crhk/holders`
+ `POST identity-hub-admin.tx.test/api/identity/v1alpha/participants/<ctx>/credentials/request`). The **callback
extension itself needs no bridge** — the bridges only substitute for the DID-validation-blocked Portal steps.
**Proper fix (removes all bridges):** run an in-cluster Universal Resolver and point `UNIVERSALRESOLVERADDRESS`
at it (or relax that validation for the sandbox) so `did:web:*.tx.test` resolves.

## 8. Fixes baked into this deploy (what a plain upstream deploy is missing)

- **Extension (identityhub branch):** dot-separated `@Setting` keys (env-mappable; hyphenated keys are
  unreachable via env vars) + `HttpClient` pinned to **HTTP/1.1** (JDK default HTTP/2 hangs h2c over cleartext).
- **`values-callback-activation.yaml`** (new): pins the IH super-user key; callback env with client `sa-cl24-01`.
- **`values-connector-persistence.yaml`** (new): connector Postgres PVCs + control-plane probe widening.
- **`values-combined-portal-additions.yaml`:** worker `IDENTITYHUB__BASEADDRESS` → **admin** host
  `identity-hub-admin.tx.test` (public host 405s on POST /participants); mailer → **`smtp4dev:25`** (default
  points at an SMTP-less host → 75 s connect-timeout per mail, starving the worker); Portal apiKey = pinned key.
- **Seed idempotency guard** (`charts/tx-data-provider/templates/post-install-identityhub-seed.yaml`): skip
  re-requesting a credential already ISSUED (prevents duplicate VCs on re-runs).
- **Test-data seeding BPN fix** (`configmap-portal-testdata-seeding.yaml`): plain BPN, not the connector DID.

## 9. Gotchas quick-reference

- IH credentials API uses the **PLAIN** participantContextId in the URL (EDC 0.17.0 / IH #937), not base64.
- Postgres IH port layout differs: identity **8082**, credentials 8083, did 8084, sts 8087.
- The super-user API key is logged only on FIRST creation → pin it (done). `curl` is not in the IH pod → use
  `kubectl port-forward` or the ingress.
- Full Docker/VM-restart durability additionally needs `umbrella-vault` in persistent/Raft mode (dev-mode Vault
  loses signing keys on Vault restart); the Postgres IH already survives an IH **pod** restart.
- Right after Phase 2, while CentralIDP finishes (re)seeding its realm, the extension may briefly log its
  seeded-holder callbacks as `returned 401 (treating as already-handled)` — the token was minted before the
  realm was ready. Once CentralIDP settles it becomes `404` (auth OK; no SUBMITTED application for a seeded BPN).
  A fresh `sa-cl24-01` client-credentials token carries `update_application_{bpn,membership}_credential` and
  the callback endpoint returns 404 for seeded BPNs — this is the expected steady state.
- Phase 2 transients that self-heal (do NOT indicate failure): `portal-portal-migrations` shows a few `Error`
  pods (DB-not-ready retries) before the Job reports `Complete`; `bpdm-gate`/`bpdm-cleaning-service-dummy`
  crashloop until CentralIDP's realm seeding completes, then reach 1/1.

---

## 10. Rebuild verification log (2026-07-16)

Ran this runbook from a full teardown (deleted the kind cluster) on a clean box. Results:
- §2 images: IdentityHub rebuilt from `d158667` + extension (`PortalCredentialCallback` present in
  `/app/identityhub.jar`); other 5 source images + 4 portal `:be293` images present.
- §3 cluster/ingress/webhook: OK (added the node-Ready wait above after the first run raced).
- §4: `hack/helm-dependencies.bash` → "All charts up to date"; **no `tmpcharts-*` leftover**; 12 images on node.
- §5 Phase 1: `deployed`, DCP smoke test **GREEN**, IH seeded **4 credentials/holder (state 500)**.
- §6 Phase 2: `deployed`; connector PVCs persisted so **DCP stayed GREEN** across the upgrade (no schema wipe);
  extension logs `started (scanning every 10s)` and **delivers callbacks**; migration Job `Complete`; BPDM 1/1.
- §7 onboarding: browser-driven (requires the operator); the callback + checklist-advance path was proven in
  the prior session (204 → BPNL_CREDENTIAL/MEMBERSHIP_CREDENTIAL DONE) and depends on the §7 DID-resolver bridge.

Conclusion: the documented §2–§6 process reproduces the durable stack exactly; §7 is accurate but needs the
browser step + the documented bridge until a local Universal Resolver is added.
