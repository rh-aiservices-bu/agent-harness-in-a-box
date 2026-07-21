#!/bin/bash
# Verify Demo 5: Check OpenShell gateway and Hermes sandbox.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

NAMESPACE="${NAMESPACE:-openshell-demo-hermes}"
SANDBOX_NAME="${1:-hermes-demo}"
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
echo " Verify Demo 5: Hermes Agent"
echo "============================================"
echo ""

step "OpenShell infrastructure checks"
check "Agent Sandbox CRD exists" oc get crd sandboxes.agents.x-k8s.io
check "OpenShell namespace exists" oc get ns "$NAMESPACE"
check "Gateway pod running" oc -n "$NAMESPACE" wait --for=condition=Ready pod -l app.kubernetes.io/name=openshell --timeout=10s
check "Gateway service exists" oc -n "$NAMESPACE" get svc openshell
check "Gateway route exists" oc -n "$NAMESPACE" get route openshell-gw

step "Sandbox checks"
export PATH="$HOME/bin:$PATH"

SANDBOX_STATUS=$(openshell sandbox list 2>/dev/null | grep "$SANDBOX_NAME" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $NF}' || echo "")
if [ "$SANDBOX_STATUS" = "Ready" ]; then
    info "PASS: Sandbox '$SANDBOX_NAME' is Ready"
    PASSED=$((PASSED + 1))

    HERMES_VER=$(openshell sandbox exec --name "$SANDBOX_NAME" -- sh -c 'export PATH="/sandbox/.local/bin:$PATH" && hermes --version' 2>&1 | grep -v "Using sandbox" || echo "")
    if [ -n "$HERMES_VER" ]; then
        info "PASS: Hermes version: $HERMES_VER"
        PASSED=$((PASSED + 1))
    else
        error "FAIL: Hermes not found in sandbox"
        FAILED=$((FAILED + 1))
    fi

    if [ -f "$REPO_ROOT/.env" ]; then
        source "$REPO_ROOT/.env"
        LLM_CODE=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -s -o /dev/null -w "%{http_code}" -X POST "${LITELLM_BASE_URL}/chat/completions" -H "Authorization: Bearer ${LITELLM_API_KEY}" -H "Content-Type: application/json" -d '{"model":"'"${LITELLM_MODEL:-gemini-2.5-pro}"'","messages":[{"role":"user","content":"Say ok"}],"max_tokens":5}' 2>&1 | grep -v "Using sandbox")
        if [ "$LLM_CODE" = "200" ]; then
            info "PASS: LiteLLM API (HTTP 200)"
            PASSED=$((PASSED + 1))
        else
            error "FAIL: LiteLLM API (HTTP $LLM_CODE)"
            FAILED=$((FAILED + 1))
        fi
    fi
elif [ -n "$SANDBOX_STATUS" ]; then
    error "FAIL: Sandbox '$SANDBOX_NAME' status: $SANDBOX_STATUS (expected Ready)"
    FAILED=$((FAILED + 1))
else
    info "SKIP: Sandbox '$SANDBOX_NAME' not found (run setup-sandbox.sh first)"
fi

step "RHOAI MLflow checks"
OCP_TOKEN=$(oc whoami -t 2>/dev/null || true)
if [ -n "$OCP_TOKEN" ]; then
    if [ -f "$REPO_ROOT/.env" ]; then
        source "$REPO_ROOT/.env"
    fi
    MLF_EXT_URI="https://mlflow-redhat-ods-applications.${OCP_APPS_DOMAIN:-apps.example.com}"
    MLF_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $OCP_TOKEN" "${MLF_EXT_URI}/health" 2>/dev/null)
    if [ "$MLF_CODE" = "200" ]; then
        info "PASS: RHOAI MLflow health (HTTP 200)"
        PASSED=$((PASSED + 1))
    else
        info "SKIP: RHOAI MLflow not available (HTTP $MLF_CODE) - optional component"
    fi
else
    info "SKIP: RHOAI MLflow (no OCP token)"
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
