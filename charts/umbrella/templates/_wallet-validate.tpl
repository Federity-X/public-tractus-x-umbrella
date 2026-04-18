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
{{- $stubEnabled := $stubMap.enabled | default false -}}
{{- $ihEnabled := $ihMap.enabled | default false -}}
{{- if and $stubEnabled $ihEnabled -}}
{{- fail "identity-and-trust-bundle: only one of `ssi-dim-wallet-stub.enabled` or `identity-hub.enabled` may be true at a time" -}}
{{- end -}}
{{- $wallet := .Values.wallet | default dict -}}
{{- $mode := $wallet.mode | default "stub" -}}
{{- if and (eq $mode "stub") $ihEnabled -}}
{{- fail "wallet.mode=stub but identity-hub is enabled; set wallet.mode=identityHub or disable identity-hub" -}}
{{- end -}}
{{- if and (eq $mode "identityHub") $stubEnabled -}}
{{- fail "wallet.mode=identityHub but ssi-dim-wallet-stub is enabled; set wallet.mode=stub or disable the stub" -}}
{{- end -}}
{{- end -}}
