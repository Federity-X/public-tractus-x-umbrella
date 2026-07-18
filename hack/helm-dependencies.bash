#!/bin/bash

# Check if any repositories is present
if ! helm repo list ; then
  echo "Need to add repos"
  helm repo add tractusx https://eclipse-tractusx.github.io/charts/dev
  helm repo add hashicorp https://helm.releases.hashicorp.com
  helm repo add runix https://helm.runix.net
  helm repo add bitnami https://charts.bitnami.com/bitnami
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
  helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo add grafana https://grafana.github.io/helm-charts
  helm repo add cert-manager https://charts.jetstack.io
  helm repo add external-secrets https://charts.external-secrets.io
else
  echo "Checking and adding missing repositories..."
  
  # Check for each required repository and add if missing
  if ! helm repo list | grep -q "^tractusx[[:space:]]"; then
    echo "Adding tractusx repository..."
    helm repo add tractusx https://eclipse-tractusx.github.io/charts/dev
  fi

  if ! helm repo list | grep -q "^hashicorp[[:space:]]"; then
    echo "Adding hashicorp repository..."
    helm repo add hashicorp https://helm.releases.hashicorp.com
  fi

  if ! helm repo list | grep -q "^runix[[:space:]]"; then
    echo "Adding runix repository..."
    helm repo add runix https://helm.runix.net
  fi

  if ! helm repo list | grep -q "^bitnami[[:space:]]"; then
    echo "Adding bitnami repository..."
    helm repo add bitnami https://charts.bitnami.com/bitnami
  fi
  
  if ! helm repo list | grep -q "^open-telemetry[[:space:]]"; then
    echo "Adding open-telemetry repository..."
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
  fi
  
  if ! helm repo list | grep -q "^jaegertracing[[:space:]]"; then
    echo "Adding jaegertracing repository..."
    helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
  fi
  
  if ! helm repo list | grep -q "^prometheus-community[[:space:]]"; then
    echo "Adding prometheus-community repository..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  fi
  
  if ! helm repo list | grep -q "^grafana[[:space:]]"; then
    echo "Adding grafana repository..."
    helm repo add grafana https://grafana.github.io/helm-charts
  fi
  
  if ! helm repo list | grep -q "^cert-manager[[:space:]]"; then
    echo "Adding cert-manager repository..."
    helm repo add cert-manager https://charts.jetstack.io
  fi

  if ! helm repo list | grep -q "^external-secrets[[:space:]]"; then
    echo "Adding external-secrets repository..."
    helm repo add external-secrets https://charts.external-secrets.io
  fi
fi

CHARTS_DIR="./charts"
TX_DATA_PROVIDER_DIR="$CHARTS_DIR/tx-data-provider"
UMBRELLA_DIR="$CHARTS_DIR/umbrella"

echo "🔄 Updating Helm repositories..."
helm repo update

echo "🔍 Updating dependencies for Helm charts under '$CHARTS_DIR'..."

# Update dependencies for all charts except tx-data-provider and umbrella
for chartdir in "$CHARTS_DIR"/*; do
  if [[ -d "$chartdir" && -f "$chartdir/Chart.yaml" && "$chartdir" != "$TX_DATA_PROVIDER_DIR" && "$chartdir" != "$UMBRELLA_DIR" ]]; then
    echo -e "\n📦 Updating dependencies for chart: $chartdir"
    helm dependency update "$chartdir" --skip-refresh
  fi
done

# Update tx-data-provider and umbrella at the end
echo -e "\n📦 Updating dependencies for chart: $TX_DATA_PROVIDER_DIR"
helm dependency update "$TX_DATA_PROVIDER_DIR" --skip-refresh

echo -e "\n📦 Updating dependencies for chart: $UMBRELLA_DIR"
helm dependency update "$UMBRELLA_DIR" --skip-refresh

# BE-293: the upstream portal chart hardcodes its backend env vars and has no way to expose the
# IdentityHub onboarding-wallet config (see hack/patches + docs/internal/BE-293-architecture-callback.md).
# Patch the freshly-fetched chart to add the (opt-in, disabled-by-default) IdentityHub env block.
# helm dependency update re-fetches the pristine chart each run, so re-applying every time is idempotent.
PORTAL_PATCH="./hack/patches/portal-2.6.0-be293-identityhub.patch"
PORTAL_TGZ=$(ls "$UMBRELLA_DIR"/charts/portal-*.tgz 2>/dev/null | head -1)
# Fail FAST (no silent warn-and-continue): an unpatched portal chart renders NONE of the
# umbrella's portal.backend.processesworker.{identityHub,dim} values (the IDENTITYHUB__* +
# universal-resolver env block simply vanishes), so the worker starts with walletProvider=IdentityHub
# but empty settings and onboarding fails deep at runtime with no pointer back here. Better to break
# the bootstrap loudly than to install a silently-broken chart.
if [[ ! -f "$PORTAL_PATCH" ]]; then
  echo "❌ BE-293 portal patch not found: $PORTAL_PATCH" >&2
  exit 1
fi
if [[ -z "$PORTAL_TGZ" || ! -f "$PORTAL_TGZ" ]]; then
  echo "❌ portal chart tarball not found under $UMBRELLA_DIR/charts — did 'helm dependency update' fetch it?" >&2
  exit 1
fi
# The patch targets portal-2.6.0 specifically; a version bump must be re-cut, not patched blind.
if [[ "$(basename "$PORTAL_TGZ")" != "portal-2.6.0.tgz" ]]; then
  echo "❌ portal chart is $(basename "$PORTAL_TGZ") but the BE-293 patch targets portal-2.6.0.tgz." >&2
  echo "   Re-cut hack/patches/portal-*-be293-identityhub.patch for the new version before continuing." >&2
  exit 1
fi
echo -e "\n🩹 Applying BE-293 IdentityHub patch to $(basename "$PORTAL_TGZ")..."
_tmp="$(mktemp -d)"
tar xzf "$PORTAL_TGZ" -C "$_tmp"
if patch -p1 -d "$_tmp/portal" < "$PORTAL_PATCH" >/dev/null; then
  helm package "$_tmp/portal" -d "$UMBRELLA_DIR/charts" >/dev/null
  echo "   portal chart patched + repackaged (IdentityHub wallet config exposed)."
else
  rm -rf "$_tmp"
  echo "❌ BE-293 portal patch did not apply cleanly. The umbrella's IdentityHub/DIM worker env" >&2
  echo "   would be SILENTLY dropped and onboarding would fail at runtime. Fix the patch first." >&2
  exit 1
fi
rm -rf "$_tmp"

echo -e "\n✅ All charts up to date!"
