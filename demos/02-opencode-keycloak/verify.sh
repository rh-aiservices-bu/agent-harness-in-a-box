#!/bin/bash
# Verify Demo 2: Check Keycloak OIDC and OpenShell integration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

NAMESPACE="${NAMESPACE:-openshell}"
KC_NAMESPACE="${KC_NAMESPACE:-openshell-keycloak}"
PASSED=0
FAILED=0

check() {
    local name="$1"
    shift
    if "$@" &>/dev/null; then
        info "PASS: $name"
        PASSED=$((PASSED + 1))
    else
        error "FAIL: $name"
        FAILED=$((FAILED + 1))
    fi
}

echo "============================================"
echo " Verify Demo 2: OpenCode + Keycloak"
echo "============================================"
echo ""

step "Keycloak checks"
check "Keycloak namespace exists" oc get ns "$KC_NAMESPACE"
check "Keycloak pod running" oc -n "$KC_NAMESPACE" wait --for=condition=Ready pod -l app=keycloak --timeout=10s
check "Keycloak route exists" oc -n "$KC_NAMESPACE" get route keycloak

KC_ROUTE=$(oc -n "$KC_NAMESPACE" get route keycloak -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$KC_ROUTE" ]; then
    check "OIDC discovery endpoint" curl -sfk --max-time 5 "https://$KC_ROUTE/realms/openshell/.well-known/openid-configuration"

    # Test token acquisition via password grant
    TOKEN_RESPONSE=$(curl -sfk --max-time 10 \
        -X POST "https://$KC_ROUTE/realms/openshell/protocol/openid-connect/token" \
        -d "grant_type=password" \
        -d "client_id=openshell-cli" \
        -d "username=admin@test" \
        -d "password=admin" 2>/dev/null || echo "")
    if echo "$TOKEN_RESPONSE" | grep -q "access_token"; then
        info "PASS: Token acquisition (admin@test)"
        PASSED=$((PASSED + 1))
    else
        error "FAIL: Token acquisition (admin@test)"
        FAILED=$((FAILED + 1))
    fi
fi

step "OpenShell checks"
check "Agent Sandbox CRD exists" oc get crd sandboxes.agents.x-k8s.io
check "OpenShell namespace exists" oc get ns "$NAMESPACE"
check "Gateway pod running" oc -n "$NAMESPACE" wait --for=condition=Ready pod -l app.kubernetes.io/name=openshell --timeout=10s
check "Gateway service exists" oc -n "$NAMESPACE" get svc openshell
check "Gateway route exists" oc -n "$NAMESPACE" get route openshell-gw

step "MLflow checks (optional)"
if oc -n "$NAMESPACE" get deployment mlflow &>/dev/null; then
    check "MLflow pod running" oc -n "$NAMESPACE" wait --for=condition=Ready pod -l app=mlflow --timeout=10s
    check "MLflow service exists" oc -n "$NAMESPACE" get svc mlflow
    MLF_ROUTE=$(oc -n "$NAMESPACE" get route mlflow -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$MLF_ROUTE" ]; then
        check "MLflow health endpoint" curl -sf --max-time 5 "http://$MLF_ROUTE/health"
    fi
else
    info "SKIP: MLflow not deployed (optional)"
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
