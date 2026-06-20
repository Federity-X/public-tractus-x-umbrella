#!/usr/bin/env bash
# #############################################################################
# Copyright (c) 2026 Contributors to the Eclipse Foundation
#
# See the NOTICE file(s) distributed with this work for additional
# information regarding copyright ownership.
#
# This program and the accompanying materials are made available under the
# terms of the Apache License, Version 2.0 which is available at
# https://www.apache.org/licenses/LICENSE-2.0.
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
#
# SPDX-License-Identifier: Apache-2.0
# #############################################################################
#
# DCP end-to-end data-transfer smoke test for the umbrella IdentityHub profile.
#
# Drives the full Decentralized Claims Protocol (DCP) data-exchange flow that
# the Bruno collection (docs/common/api/bruno) walks manually, but as a single
# self-verifying, automatable run:
#
#   PROVIDER (Bob)            CONSUMER (Alice)
#   --------------            ----------------
#   1. seed submodel data
#   2. create asset
#   3. create access policy
#   4. create usage policy
#   5. create contract def
#                             6. catalog request        ← first cross-connector DCP call
#                             7. EDR / contract negotiation
#                             8. poll cached EDR (transfer process)
#                             9. fetch EDR data address (endpoint + token)
#                            10. GET the asset bytes via the consumer data plane
#
# It is deliberately STAGE-AWARE: on failure it prints exactly which DCP stage
# broke (provision / catalog / negotiation / transfer / fetch) so a red run
# tells you where in the DCP chain the bundle is still misconfigured. A green
# run means the full data transfer worked end-to-end over DCP.
#
# Defaults target the SHARED IdentityHub profile
# (charts/values-test-data-exchange-identity-hub.yaml). Every input is an env
# var override, so the same script validates the stub profile (set
# PROVIDER_DID to the ssi-dim-wallet-stub DID) or the per-participant profile
# (set PROVIDER_DID to the provider's own IH host) without edits.
#
# Prereqs: bash, curl, jq, and host DNS for *.tx.test pointing at the cluster
# ingress (see docs/user/*/installation). Run from anywhere.
#
#   ./hack/dcp-data-transfer-smoke.sh
#   PROVIDER_DID=did:web:ssi-dim-wallet-stub.tx.test:BPNL00000003AYRE \
#     ./hack/dcp-data-transfer-smoke.sh        # validate the stub profile instead
# #############################################################################

set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration (all overridable via environment).
# ----------------------------------------------------------------------------
PROVIDER_MGMT="${PROVIDER_MGMT:-http://dataprovider-controlplane.tx.test/management/v3}"
PROVIDER_DSP="${PROVIDER_DSP:-http://dataprovider-controlplane.tx.test/api/v1/dsp}"
PROVIDER_SUBMODEL="${PROVIDER_SUBMODEL:-http://dataprovider-submodelserver.tx.test}"
CONSUMER_MGMT="${CONSUMER_MGMT:-http://dataconsumer-1-controlplane.tx.test/management/v3}"

PROVIDER_APIKEY="${PROVIDER_APIKEY:-TEST2}"   # Bob's management X-Api-Key
CONSUMER_APIKEY="${CONSUMER_APIKEY:-TEST1}"   # Alice's management X-Api-Key

# Counterparty identity as seen on the dataspace protocol layer. For the IH
# profile this is the provider's did:web hosted by the IdentityHub. This is the
# ONE value that differs between the stub and IdentityHub profiles.
PROVIDER_DID="${PROVIDER_DID:-did:web:identity-hub.tx.test:BPNL00000003AYRE}"
CONSUMER_BPN="${CONSUMER_BPN:-BPNL00000003AZQP}"   # goes into the access policy

DSP_VERSION="${DSP_VERSION:-2025-1}"
PROTOCOL="${PROTOCOL:-dataspace-protocol-http:2025-1}"

# Unique per run so every invocation negotiates a fresh contract and never
# trips over stale provider-side state. Override to pin specific ids.
RUN_ID="${RUN_ID:-$(date +%s)}"
ASSET_ID="${ASSET_ID:-smoke-asset-${RUN_ID}}"
ACCESS_POLICY_ID="${ACCESS_POLICY_ID:-smoke-access-${RUN_ID}}"
USAGE_POLICY_ID="${USAGE_POLICY_ID:-smoke-usage-${RUN_ID}}"
CONTRACT_ID="${CONTRACT_ID:-smoke-contract-${RUN_ID}}"

# Submodel payload + the path it is stored/fetched at. The marker string is
# asserted to be present in the finally-fetched bytes (proves real transfer).
DATA_PATH="${DATA_PATH:-urn:uuid:b77c6d51-cd1f-4c9d-b5d4-091b22dd306b}"
DATA_MARKER="urn:uuid:2c57b0e9-a653-411d-bdcd-64787e9fd3a7"

POLL_RETRIES="${POLL_RETRIES:-40}"   # × POLL_DELAY = max wait per async stage
POLL_DELAY="${POLL_DELAY:-3}"        # seconds

# When the *.tx.test hosts are NOT in /etc/hosts, set INGRESS_IP to the cluster
# ingress address and every request is sent with `curl --resolve`. For kind with
# host ports 80/443 mapped, INGRESS_IP=127.0.0.1. Leave empty if /etc/hosts (or
# real DNS) already resolves the hosts.
INGRESS_IP="${INGRESS_IP:-}"

# ----------------------------------------------------------------------------
# Output helpers.
# ----------------------------------------------------------------------------
if [ -t 1 ]; then C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
else C_R=; C_G=; C_Y=; C_B=; C_0=; fi

STAGE="startup"
log()  { printf '%s[smoke]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[smoke]  ✓ %s%s\n' "$C_G" "$*" "$C_0"; }
warn() { printf '%s[smoke]  ! %s%s\n' "$C_Y" "$*" "$C_0"; }
die()  {
  printf '%s[smoke]  ✗ FAILED at stage: %s%s\n' "$C_R" "$STAGE" "$C_0" >&2
  printf '%s[smoke]    %s%s\n' "$C_R" "$*" "$C_0" >&2
  [ -n "${LAST_BODY:-}" ] && printf '[smoke]    last response: %s\n' "$(printf '%s' "$LAST_BODY" | head -c 1200)" >&2
  exit 1
}

command -v jq   >/dev/null || { echo "jq is required"   >&2; exit 2; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }

LAST_BODY=""
LAST_CODE=""

# Host/port extraction for `--resolve` (bash 3.2 safe).
url_host() { local u="${1#*://}"; u="${u%%/*}"; printf '%s' "${u%%:*}"; }
url_port() {
  local u="$1" h="${1#*://}"; h="${h%%/*}"
  case "$h" in *:*) printf '%s' "${h##*:}";; *) case "$u" in https://*) printf 443;; *) printf 80;; esac;; esac
}

# req METHOD URL APIKEY [JSON_BODY] -> sets LAST_BODY, LAST_CODE
req() {
  local method="$1" url="$2" key="$3" body="${4:-}"
  local tmp; tmp="$(mktemp)"
  local -a args=(-sS -L --connect-timeout 10 --max-time 60 -o "$tmp" -w '%{http_code}' -X "$method" "$url")
  [ -n "$INGRESS_IP" ] && args+=(--resolve "$(url_host "$url"):$(url_port "$url"):$INGRESS_IP")
  [ -n "$key" ]  && args+=(-H "X-Api-Key: $key")
  if [ -n "$body" ]; then args+=(-H 'Content-Type: application/json' --data-raw "$body"); fi
  # curl's -w always prints a status (000 on connect failure), so don't add a
  # `|| echo 000` fallback — that would double-print on curl's non-zero exit.
  LAST_CODE="$(curl "${args[@]}" 2>/dev/null)"; LAST_CODE="${LAST_CODE:-000}"
  LAST_BODY="$(cat "$tmp")"; rm -f "$tmp"
}

# ----------------------------------------------------------------------------
log "DCP data-transfer smoke test"
log "  provider mgmt : $PROVIDER_MGMT  (key $PROVIDER_APIKEY)"
log "  consumer mgmt : $CONSUMER_MGMT  (key $CONSUMER_APIKEY)"
log "  counterPartyId: $PROVIDER_DID"
log "  run id        : $RUN_ID  (asset=$ASSET_ID)"
echo

# ============================================================================
# PROVIDER: provision data, asset, policies, contract definition.
# ============================================================================
STAGE="provision:seed-data"
log "1/10  seed submodel data at $DATA_PATH"
req POST "$PROVIDER_SUBMODEL/$DATA_PATH" "" "$(cat <<JSON
{
  "parentParts": [{
    "validityPeriod": {"validFrom": "2023-03-21T08:47:14.438+01:00", "validTo": "2024-08-02T09:00:00.000+01:00"},
    "parentCatenaXId": "urn:uuid:0733946c-59c6-41ae-9570-cb43a6e4c79e",
    "quantity": {"quantityNumber": 2.5, "measurementUnit": "unit:litre"},
    "createdOn": "2022-02-03T14:48:54.709Z", "lastModifiedOn": "2022-02-03T14:48:54.709Z"
  }],
  "catenaXId": "$DATA_MARKER"
}
JSON
)"
case "$LAST_CODE" in 2*) ok "data stored ($LAST_CODE)";; *) die "submodel server returned $LAST_CODE";; esac

STAGE="provision:asset"
log "2/10  create asset $ASSET_ID"
req POST "$PROVIDER_MGMT/assets" "$PROVIDER_APIKEY" "$(cat <<JSON
{
  "@context": {"@vocab": "https://w3id.org/edc/v0.0.1/ns/", "edc": "https://w3id.org/edc/v0.0.1/ns/",
    "tx": "https://w3id.org/tractusx/v0.0.1/ns/", "cx-policy": "https://w3id.org/catenax/policy/",
    "odrl": "http://www.w3.org/ns/odrl/2/"},
  "@id": "$ASSET_ID",
  "properties": {"description": "DCP smoke-test asset"},
  "dataAddress": {"@type": "DataAddress", "type": "HttpData", "proxyPath": "true",
    "proxyMethod": "true", "proxyQueryParams": "true", "proxyBody": "true",
    "baseUrl": "$PROVIDER_SUBMODEL"}
}
JSON
)"
case "$LAST_CODE" in 2*) ok "asset created ($LAST_CODE)";; 409) warn "asset exists (409)";; *) die "asset create returned $LAST_CODE";; esac

STAGE="provision:access-policy"
log "3/10  create access policy $ACCESS_POLICY_ID"
req POST "$PROVIDER_MGMT/policydefinitions" "$PROVIDER_APIKEY" "$(cat <<JSON
{
  "@context": ["https://w3id.org/dspace/2025/1/odrl-profile.jsonld",
    "https://w3id.org/catenax/2025/9/policy/context.jsonld",
    {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"}],
  "@id": "$ACCESS_POLICY_ID", "@type": "PolicyDefinition",
  "policy": {"@type": "Set", "permission": [{"action": "access", "constraint": [{"and": [
    {"leftOperand": "Membership", "operator": "eq", "rightOperand": "active"},
    {"leftOperand": "FrameworkAgreement", "operator": "eq", "rightOperand": "DataExchangeGovernance:1.0"},
    {"leftOperand": "BusinessPartnerNumber", "operator": "isAnyOf", "rightOperand": ["$CONSUMER_BPN"]}
  ]}]}]}
}
JSON
)"
case "$LAST_CODE" in 2*) ok "access policy created ($LAST_CODE)";; 409) warn "exists (409)";; *) die "access policy returned $LAST_CODE";; esac

STAGE="provision:usage-policy"
log "4/10  create usage policy $USAGE_POLICY_ID"
req POST "$PROVIDER_MGMT/policydefinitions" "$PROVIDER_APIKEY" "$(cat <<JSON
{
  "@context": ["https://w3id.org/dspace/2025/1/odrl-profile.jsonld",
    "https://w3id.org/catenax/2025/9/policy/context.jsonld",
    {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"}, {}],
  "@type": "PolicyDefinition", "@id": "$USAGE_POLICY_ID",
  "policy": {"@type": "Set", "permission": [{"action": "use", "constraint": {"and": [
    {"leftOperand": "Membership", "operator": "eq", "rightOperand": "active"},
    {"leftOperand": "FrameworkAgreement", "operator": "eq", "rightOperand": "DataExchangeGovernance:1.0"},
    {"leftOperand": "UsagePurpose", "operator": "isAnyOf", "rightOperand": ["cx.core.industrycore:1"]}
  ]}}], "prohibition": [], "obligation": []}
}
JSON
)"
case "$LAST_CODE" in 2*) ok "usage policy created ($LAST_CODE)";; 409) warn "exists (409)";; *) die "usage policy returned $LAST_CODE";; esac

STAGE="provision:contract-def"
log "5/10  create contract definition $CONTRACT_ID"
req POST "$PROVIDER_MGMT/contractdefinitions" "$PROVIDER_APIKEY" "$(cat <<JSON
{
  "@context": {"edc": "https://w3id.org/edc/v0.0.1/ns/"},
  "@id": "$CONTRACT_ID", "@type": "ContractDefinition",
  "accessPolicyId": "$ACCESS_POLICY_ID", "contractPolicyId": "$USAGE_POLICY_ID",
  "assetsSelector": [{"@type": "CriterionDto",
    "operandLeft": "https://w3id.org/edc/v0.0.1/ns/id", "operator": "=", "operandRight": "$ASSET_ID"}]
}
JSON
)"
case "$LAST_CODE" in 2*) ok "contract definition created ($LAST_CODE)";; 409) warn "exists (409)";; *) die "contract def returned $LAST_CODE";; esac

# ============================================================================
# CONSUMER: catalog -> negotiation -> transfer -> fetch.
# ============================================================================
STAGE="catalog"
log "6/10  request catalog from provider (first cross-connector DCP call)"
req POST "$CONSUMER_MGMT/catalog/request" "$CONSUMER_APIKEY" "$(cat <<JSON
{
  "@context": [{"@vocab": "https://w3id.org/edc/v0.0.1/ns/"}],
  "@type": "CatalogRequest",
  "counterPartyAddress": "$PROVIDER_DSP/$DSP_VERSION",
  "counterPartyId": "$PROVIDER_DID",
  "protocol": "$PROTOCOL",
  "querySpec": {"offset": 0, "limit": 50, "filterExpression": [
    {"operandLeft": "https://w3id.org/edc/v0.0.1/ns/id", "operator": "=", "operandRight": "$ASSET_ID"}]}
}
JSON
)"
[ "${LAST_CODE:0:1}" = "2" ] || die "catalog request returned $LAST_CODE — DCP auth/presentation likely failing (check STS, trusted issuers, credential issuance)"
# dataset and hasPolicy may each be a single object or an array (JSON-LD).
OFFER_ID="$(printf '%s' "$LAST_BODY" | jq -r '
  (.dataset // []) as $d
  | (if ($d|type)=="array" then $d[0] else $d end) as $ds
  | ($ds.hasPolicy // []) as $hp
  | (if ($hp|type)=="array" then $hp[0] else $hp end)
  | ."@id" // empty')"
[ -n "$OFFER_ID" ] || die "catalog returned 200 but advertises no offer for asset $ASSET_ID (contract definition/policy not matched)"
ok "catalog returned an offer: $OFFER_ID"

# Stages 7-8 are wrapped in a bounded retry. The provider resolves the
# counterparty BPN from BDRS on ContractNegotiationFinalized (async, via the
# tractusx-edc EventContractNegotiationSubscriber). On the FIRST negotiation
# after a fresh install the connector's BdrsClient directory cache is cold, and
# the consumer-initiated transfer can win the race against that resolution —
# the provider then terminates the transfer with "No BPN entry found for
# agreement" (a terminal, non-retryable connector state). The failed attempt
# warms the BdrsClient cache, so a second negotiation succeeds. A real policy
# rejection (negotiation TERMINATED) still fails fast below.
NEG_ATTEMPTS="${NEG_ATTEMPTS:-2}"
EDR_POLL="${EDR_POLL:-10}"   # a successful transfer yields the EDR within seconds
NEG_ID=""; TP_ID=""
for attempt in $(seq 1 "$NEG_ATTEMPTS"); do
  STAGE="negotiation"
  if [ "$attempt" -gt 1 ]; then
    log "7/10  start EDR negotiation (attempt $attempt/$NEG_ATTEMPTS — warming the provider's BDRS cache)"
  else
    log "7/10  start EDR negotiation"
  fi
  req POST "$CONSUMER_MGMT/edrs" "$CONSUMER_APIKEY" "$(cat <<JSON
{
  "@context": ["http://www.w3.org/ns/odrl.jsonld",
    "https://w3id.org/catenax/2025/9/policy/context.jsonld",
    {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"}],
  "@type": "ContractRequest",
  "counterPartyAddress": "$PROVIDER_DSP/$DSP_VERSION",
  "protocol": "$PROTOCOL",
  "policy": {"@id": "$OFFER_ID", "@type": "Offer", "assigner": "$PROVIDER_DID", "target": "$ASSET_ID",
    "permission": [{"action": "use", "constraint": [{"and": [
      {"leftOperand": "Membership", "operator": "eq", "rightOperand": "active"},
      {"leftOperand": "FrameworkAgreement", "operator": "eq", "rightOperand": "DataExchangeGovernance:1.0"},
      {"leftOperand": "UsagePurpose", "operator": "isAnyOf", "rightOperand": "cx.core.industrycore:1"}
    ]}]}], "prohibition": [], "obligation": []},
  "callbackAddresses": []
}
JSON
)"
  [ "${LAST_CODE:0:1}" = "2" ] || die "EDR negotiation request returned $LAST_CODE"
  NEG_ID="$(printf '%s' "$LAST_BODY" | jq -r '."@id" // empty')"
  [ -n "$NEG_ID" ] || die "negotiation response had no @id"
  ok "negotiation started: $NEG_ID"

  STAGE="negotiation:poll"
  log "      poll negotiation until FINALIZED"
  NEG_STATE=""
  for i in $(seq 1 "$POLL_RETRIES"); do
    req GET "$CONSUMER_MGMT/contractnegotiations/$NEG_ID" "$CONSUMER_APIKEY"
    NEG_STATE="$(printf '%s' "$LAST_BODY" | jq -r '.state // ."edc:state" // empty')"
    case "$NEG_STATE" in
      FINALIZED) ok "negotiation FINALIZED (after ${i}×${POLL_DELAY}s)"; break;;
      TERMINATED|ERROR) die "negotiation reached terminal state $NEG_STATE (policy not satisfied / credential rejected)";;
    esac
    sleep "$POLL_DELAY"
  done
  [ "$NEG_STATE" = "FINALIZED" ] || die "negotiation did not finalize (last state: ${NEG_STATE:-unknown})"

  STAGE="transfer:edr-cache"
  log "8/10  poll cached EDR for the transfer process"
  TP_ID=""
  for i in $(seq 1 "$EDR_POLL"); do
    req POST "$CONSUMER_MGMT/edrs/request" "$CONSUMER_APIKEY" "$(cat <<JSON
{ "@context": {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"}, "@type": "QuerySpec",
  "filterExpression": [{"operandLeft": "contractNegotiationId", "operator": "=", "operandRight": "$NEG_ID"}] }
JSON
)"
    TP_ID="$(printf '%s' "$LAST_BODY" | jq -r '
      (if type=="array" then .[0] else . end)
      | .transferProcessId // ."tx:transferProcessId" // empty')"
    [ -n "$TP_ID" ] && { ok "EDR cached, transfer process: $TP_ID"; break; }
    sleep "$POLL_DELAY"
  done
  [ -n "$TP_ID" ] && break
  if [ "$attempt" -lt "$NEG_ATTEMPTS" ]; then
    warn "no EDR for negotiation $NEG_ID within ${EDR_POLL}×${POLL_DELAY}s — likely the cold-BDRS-cache transfer race; re-negotiating to warm the cache"
  fi
done
[ -n "$TP_ID" ] || die "no EDR appeared in the cache after $NEG_ATTEMPTS negotiation attempt(s) for $NEG_ID (transfer kept terminating — check provider for 'No BPN entry found')"

STAGE="transfer:data-address"
log "9/10  fetch EDR data address (endpoint + token)"
ENDPOINT=""; TOKEN=""
for i in $(seq 1 "$POLL_RETRIES"); do
  req GET "$CONSUMER_MGMT/edrs/$TP_ID/dataaddress?auto_refresh=true" "$CONSUMER_APIKEY"
  if [ "${LAST_CODE:0:1}" = "2" ]; then
    ENDPOINT="$(printf '%s' "$LAST_BODY" | jq -r '.endpoint // empty')"
    TOKEN="$(printf '%s' "$LAST_BODY" | jq -r '.authorization // empty')"
    [ -n "$ENDPOINT" ] && [ -n "$TOKEN" ] && { ok "data address resolved: $ENDPOINT"; break; }
  fi
  sleep "$POLL_DELAY"
done
[ -n "$ENDPOINT" ] && [ -n "$TOKEN" ] || die "could not resolve EDR data address/token for transfer $TP_ID"

STAGE="fetch"
log "10/10 fetch asset bytes through the consumer data plane"
tmp="$(mktemp)"
FETCH_RESOLVE=""
[ -n "$INGRESS_IP" ] && FETCH_RESOLVE="--resolve $(url_host "$ENDPOINT"):$(url_port "$ENDPOINT"):$INGRESS_IP"
# shellcheck disable=SC2086
FETCH_CODE="$(curl -sS -L --connect-timeout 10 --max-time 60 $FETCH_RESOLVE -o "$tmp" -w '%{http_code}' -H "Authorization: $TOKEN" "$ENDPOINT/$DATA_PATH" 2>/dev/null)"; FETCH_CODE="${FETCH_CODE:-000}"
FETCH_BODY="$(cat "$tmp")"; rm -f "$tmp"
LAST_BODY="$FETCH_BODY"
[ "${FETCH_CODE:0:1}" = "2" ] || die "data fetch returned $FETCH_CODE"
printf '%s' "$FETCH_BODY" | grep -q "$DATA_MARKER" \
  || die "fetched data does not contain expected marker $DATA_MARKER — proxy returned unexpected payload"

echo
printf '%s' "$FETCH_BODY" | jq . 2>/dev/null | head -20 || printf '%s\n' "$FETCH_BODY" | head -5
echo
ok "FULL DCP DATA TRANSFER SUCCEEDED — consumer fetched the provider asset over DCP."
log "  catalog → negotiation(FINALIZED) → transfer($TP_ID) → fetch(${FETCH_CODE}) all green."
