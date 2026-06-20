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
{{- end -}}
