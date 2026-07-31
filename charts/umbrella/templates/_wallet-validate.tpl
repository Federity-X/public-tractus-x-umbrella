{{/*
*****************************************************************************
* Copyright (c) 2026 Contributors to the Eclipse Foundation
*
* SPDX-License-Identifier: Apache-2.0
*****************************************************************************
*/}}

{{/*
Wallet mutual-exclusion validator.

Fails the Helm render if more than one wallet implementation is enabled
inside identity-and-trust-bundle. Also cross-checks .Values.wallet.mode
against which wallet chart is enabled.

Call from any rendered template with: {{ include "umbrella.validateWallet" . }}
*/}}
{{- define "umbrella.validateWallet" -}}
{{- $iatBundle := (index .Values "identity-and-trust-bundle") | default dict -}}
{{- $stubMap := (index $iatBundle "ssi-dim-wallet-stub") | default dict -}}
{{- $ihMap := (index $iatBundle "identity-hub") | default dict -}}
{{- $ihPgMap := (index $iatBundle "identity-hub-postgres") | default dict -}}
{{- $stubEnabled := $stubMap.enabled | default false -}}
{{- $ihEnabled := $ihMap.enabled | default false -}}
{{- $ihPgEnabled := $ihPgMap.enabled | default false -}}
{{/* At most ONE wallet implementation may be enabled. */}}
{{- $enabledCount := 0 -}}
{{- if $stubEnabled -}}{{- $enabledCount = add1 $enabledCount -}}{{- end -}}
{{- if $ihEnabled -}}{{- $enabledCount = add1 $enabledCount -}}{{- end -}}
{{- if $ihPgEnabled -}}{{- $enabledCount = add1 $enabledCount -}}{{- end -}}
{{- if gt $enabledCount 1 -}}
{{- fail "identity-and-trust-bundle: only ONE wallet may be enabled at a time — pick exactly one of `ssi-dim-wallet-stub.enabled`, `identity-hub.enabled` (in-memory) or `identity-hub-postgres.enabled` (persistent)" -}}
{{- end -}}
{{- $wallet := .Values.wallet | default dict -}}
{{- $mode := $wallet.mode | default "stub" -}}
{{- $anyIh := or $ihEnabled $ihPgEnabled -}}
{{- if and (eq $mode "stub") $anyIh -}}
{{- fail "wallet.mode=stub but an Identity Hub variant (identity-hub / identity-hub-postgres) is enabled; set wallet.mode=identityHub or disable it" -}}
{{- end -}}
{{- if and (eq $mode "identityHub") $stubEnabled -}}
{{- fail "wallet.mode=identityHub but ssi-dim-wallet-stub is enabled; set wallet.mode=stub or disable the stub" -}}
{{- end -}}
{{/* identityHub mode requires exactly one IH variant — guard the zero case too. */}}
{{- if and (eq $mode "identityHub") (not $anyIh) -}}
{{- fail "wallet.mode=identityHub but no Identity Hub variant is enabled; enable exactly one of `identity-hub.enabled` (in-memory) or `identity-hub-postgres.enabled` (persistent)" -}}
{{- end -}}
{{- end -}}

{{/*
*****************************************************************************
* TEMPORARY image-overlay guard (#1609 demonstration era).
*
* The full DCP data-transfer flow is validated ONLY on the EDC-0.17.0-aligned
* stack (tractusx-edc main + tractusx-identityhub PR #309), which is built from
* source and pinned by the local-image overlay
* `charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml`. The bundle
* Chart.yaml files still pin the released 0.16.0 line, which CANNOT complete the
* transfer. To stop anyone silently running the non-working stack, fail the
* render when wallet.mode=identityHub is selected WITHOUT that overlay (it sets
* the `wallet.identityHub.imagesOverridden` sentinel).
*
* REMOVE this guard (and the sentinel) once tractusx-connector 0.13.0 and
* IdentityHub/IssuerService 0.17.0 are released and the bundle pins are bumped.
*****************************************************************************
*/}}
{{- define "umbrella.validateIdentityHubImageOverlay" -}}
{{- $wallet := .Values.wallet | default dict -}}
{{- $mode := $wallet.mode | default "stub" -}}
{{- if eq $mode "identityHub" -}}
{{- $ih := $wallet.identityHub | default dict -}}
{{- if not $ih.imagesOverridden -}}
{{- fail "wallet.mode=identityHub needs the EDC-0.17.0-aligned images, which are not yet on a public registry. Layer the local-image overlay `-f charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml` (it pre-loads the built images and sets wallet.identityHub.imagesOverridden=true). See docs/user/common/guides/data-exchange-identity-hub.md. This guard is removed once connector 0.13.0 + IH/IS 0.17.0 are released." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
*****************************************************************************
* Portal onboarding wallet-provider guard (BE-293).
*
* The Portal backend's Onboarding:WalletProvider is [Required] with NO default
* (it replaced the per-feature UseDimWallet flags). An empty or unknown value
* passes `helm template` but fails the worker at STARTUP ("The WalletProvider
* field is required" / a config-convert error) — a late, opaque failure. When
* the portal is enabled, fail the render instead unless
* portal.backend.walletProvider is exactly one of Dim | Custodian | IdentityHub.
*****************************************************************************
*/}}
{{- define "umbrella.validatePortalWalletProvider" -}}
{{- $portal := .Values.portal | default dict -}}
{{- if $portal.enabled -}}
{{- $backend := $portal.backend | default dict -}}
{{- $wp := $backend.walletProvider | default "" -}}
{{- if not (has $wp (list "Dim" "Custodian" "IdentityHub")) -}}
{{- fail (printf "portal.backend.walletProvider must be one of Dim|Custodian|IdentityHub when portal.enabled=true (got %q). The Portal backend's Onboarding:WalletProvider is [Required] with no default; an empty/invalid value passes `helm template` but fails worker startup at runtime. Set it explicitly in your portal overlay." $wp) -}}
{{- end -}}
{{- end -}}
{{- end -}}
