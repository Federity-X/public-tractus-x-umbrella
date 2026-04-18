{{/*
  -----------------------------------------------------------------------------
  Wallet derive helpers — single source of truth (Phase A of #1609 plan).

  Usage in other templates:

    {{ include "umbrella.wallet.didFor"                (dict "ctx" . "pid" "provider") }}
    {{ include "umbrella.wallet.participantIdFor"      (dict "ctx" . "pid" "provider") }}
    {{ include "umbrella.wallet.base64ParticipantId"   (dict "ctx" . "pid" "provider") }}
    {{ include "umbrella.wallet.credentialServiceUrl"  (dict "ctx" . "pid" "provider") }}
    {{ include "umbrella.wallet.stsUrl"                (dict "ctx" . "pid" "provider") }}
    {{ include "umbrella.wallet.issuerAdminUrl"        (dict "ctx" .) }}
    {{ include "umbrella.wallet.identityApiUrlFor"     (dict "ctx" . "pid" "provider") }}

  The `ctx` key carries the root context ($ or .) so we can read .Values.wallet.
  -----------------------------------------------------------------------------
*/}}

{{/* ---------------- base64url of participantId = role-bpn-lower ------------- */}}
{{- define "umbrella.wallet.participantIdFor" -}}
{{- $ctx := .ctx -}}
{{- $pid := .pid -}}
{{- $p := index $ctx.Values.wallet.participants $pid -}}
{{- if not $p -}}
{{- fail (printf "umbrella.wallet: unknown participant key %q" $pid) -}}
{{- end -}}
{{- printf "%s-%s" $p.role (lower $p.bpn) -}}
{{- end -}}

{{- define "umbrella.wallet.base64ParticipantId" -}}
{{- include "umbrella.wallet.participantIdFor" . | b64enc | replace "=" "" | replace "+" "-" | replace "/" "_" -}}
{{- end -}}

{{/* ---------------- DID ----------------------------------------------------- */}}
{{- define "umbrella.wallet.didFor" -}}
{{- $ctx := .ctx -}}
{{- $pid := .pid -}}
{{- $w := $ctx.Values.wallet -}}
{{- $p := index $w.participants $pid -}}
{{- if eq $w.mode "stub" -}}
{{- printf "%s:%s" $w.stub.didBase $p.bpn -}}
{{- else if eq $w.mode "identityHub" -}}
{{-   if eq $w.identityHub.topology "shared" -}}
{{-     printf "%s:%s" $w.identityHub.shared.didBase $p.bpn -}}
{{-   else -}}
{{-     $host := index $w.identityHub.perParticipant.hosts $p.bpn -}}
{{-     if not $host -}}{{- fail (printf "umbrella.wallet: no perParticipant host for BPN %s" $p.bpn) -}}{{- end -}}
{{-     printf "did:web:%s" $host -}}
{{-   end -}}
{{- else -}}
{{-   fail (printf "umbrella.wallet: unsupported mode %q" $w.mode) -}}
{{- end -}}
{{- end -}}

{{/* ---------------- IH endpoints (mode=identityHub only) ------------------- */}}
{{- define "umbrella.wallet.ihBaseUrlFor" -}}
{{- $ctx := .ctx -}}
{{- $pid := .pid -}}
{{- $w := $ctx.Values.wallet -}}
{{- if ne $w.mode "identityHub" -}}{{- fail "umbrella.wallet: ihBaseUrlFor requires wallet.mode=identityHub" -}}{{- end -}}
{{- if eq $w.identityHub.topology "shared" -}}
{{-   $w.identityHub.shared.baseUrl -}}
{{- else -}}
{{-   $p := index $w.participants $pid -}}
{{-   $host := index $w.identityHub.perParticipant.hosts $p.bpn -}}
{{-   printf "http://%s" $host -}}
{{- end -}}
{{- end -}}

{{- define "umbrella.wallet.credentialServiceUrl" -}}
{{- $base := include "umbrella.wallet.ihBaseUrlFor" . -}}
{{- $ctxId := include "umbrella.wallet.base64ParticipantId" . -}}
{{- printf "%s/api/credentials/v1/participants/%s" $base $ctxId -}}
{{- end -}}

{{- define "umbrella.wallet.stsUrl" -}}
{{- $base := include "umbrella.wallet.ihBaseUrlFor" . -}}
{{- printf "%s/api/sts" $base -}}
{{- end -}}

{{- define "umbrella.wallet.identityApiUrlFor" -}}
{{- $ctx := .ctx -}}
{{- $w := $ctx.Values.wallet -}}
{{- if eq $w.identityHub.topology "shared" -}}
{{- printf "http://%s/api/identity" $w.identityHub.shared.host -}}
{{- else -}}
{{- include "umbrella.wallet.ihBaseUrlFor" . -}}{{- "/api/identity" -}}
{{- end -}}
{{- end -}}

{{- define "umbrella.wallet.issuerAdminUrl" -}}
{{- $w := .ctx.Values.wallet -}}
{{- printf "http://%s/api/admin" $w.identityHub.shared.issuerServiceHost -}}
{{- end -}}

{{- define "umbrella.wallet.issuerIdentityUrl" -}}
{{- $w := .ctx.Values.wallet -}}
{{- printf "http://%s/api/identity" $w.identityHub.shared.issuerServiceHost -}}
{{- end -}}

{{- define "umbrella.wallet.issuerDid" -}}
{{- $w := .ctx.Values.wallet -}}
{{- if eq $w.mode "identityHub" -}}
{{- printf "did:web:%s:%s" $w.identityHub.shared.issuerServiceHost $w.operatorBpn -}}
{{- else -}}
{{- printf "%s:%s" $w.stub.didBase $w.operatorBpn -}}
{{- end -}}
{{- end -}}
