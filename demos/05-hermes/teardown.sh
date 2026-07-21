#!/bin/bash
# Teardown Demo 5: Remove OpenShell and all associated resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

NAMESPACE="${NAMESPACE:-openshell-demo-hermes}"
DELETE_CRDS="${1:-}"

echo "============================================"
echo " Teardown Demo 5: Hermes Agent"
echo "============================================"
echo ""

step "Delete OpenShell Helm release"
helm uninstall openshell --namespace "$NAMESPACE" 2>/dev/null || warn "Helm release not found"

step "Delete OpenShell Route and secrets"
oc -n "$NAMESPACE" delete route openshell-gw 2>/dev/null || true
oc -n "$NAMESPACE" delete secret openshell-jwt-keys 2>/dev/null || true
oc -n "$NAMESPACE" delete pvc openshell-data-openshell-0 2>/dev/null || true

step "Delete SCC binding"
oc adm policy remove-scc-from-user privileged -z openshell-sandbox -n "$NAMESPACE" 2>/dev/null || true

step "Delete OpenShell namespace"
oc delete ns "$NAMESPACE" 2>/dev/null || true

if [ "$DELETE_CRDS" = "--crd" ]; then
    step "Delete Agent Sandbox CRDs"
    oc delete -f \
        https://github.com/kubernetes-sigs/agent-sandbox/releases/latest/download/manifest.yaml \
        2>/dev/null || true
fi

echo ""
info "Teardown complete."
