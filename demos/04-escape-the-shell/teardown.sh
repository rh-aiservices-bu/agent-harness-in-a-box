#!/bin/bash
# Teardown Demo 4: Remove all CTF resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

NAMESPACE="${NAMESPACE:-openshell-ctf}"
DELETE_CRDS="${1:-}"

echo "============================================"
echo " Teardown Demo 4: Escape the Shell"
echo "============================================"
echo ""

step "Delete CTF sandbox"
openshell sandbox delete ctf-sandbox 2>/dev/null || true

step "Delete CTF UI resources"
oc -n "$NAMESPACE" delete route ctf-ui 2>/dev/null || true
oc -n "$NAMESPACE" delete svc ctf-ui 2>/dev/null || true
oc -n "$NAMESPACE" delete deployment ctf-ui 2>/dev/null || true
oc -n "$NAMESPACE" delete buildconfig ctf-ui 2>/dev/null || true
oc -n "$NAMESPACE" delete imagestream ctf-ui 2>/dev/null || true
oc -n "$NAMESPACE" delete configmap ctf-policies 2>/dev/null || true

step "Delete OpenShell Helm release"
helm uninstall openshell --namespace "$NAMESPACE" 2>/dev/null || warn "Helm release not found"

step "Delete Route"
oc -n "$NAMESPACE" delete route openshell-gw 2>/dev/null || true

step "Delete JWT secret"
oc -n "$NAMESPACE" delete secret openshell-jwt-keys 2>/dev/null || true

step "Delete PVC"
oc -n "$NAMESPACE" delete pvc openshell-data-openshell-0 2>/dev/null || true

step "Delete SCC binding"
oc adm policy remove-scc-from-user privileged -z openshell-sandbox -n "$NAMESPACE" 2>/dev/null || true

step "Delete namespace"
oc delete ns "$NAMESPACE" 2>/dev/null || true

if [ "$DELETE_CRDS" = "--crd" ]; then
    step "Delete Agent Sandbox CRDs"
    oc delete -f \
        https://github.com/kubernetes-sigs/agent-sandbox/releases/latest/download/manifest.yaml \
        2>/dev/null || true
fi

echo ""
info "Teardown complete."
