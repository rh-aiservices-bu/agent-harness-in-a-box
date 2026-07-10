#!/bin/bash
# Verify Demo 3: Check that Claude Code sandbox is working.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

if [ -f "$REPO_ROOT/.env" ]; then
    source "$REPO_ROOT/.env"
fi

NAMESPACE="${NAMESPACE:-openshell}"
SANDBOX_NAME="${1:-claude-demo}"
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
echo " Verify Demo 3: Claude Code"
echo "============================================"
echo ""

export PATH="$HOME/bin:$PATH"

step "OpenShell checks (from Demo 2)"
check "Gateway pod running" oc -n "$NAMESPACE" wait --for=condition=Ready pod -l app.kubernetes.io/name=openshell --timeout=10s

step "Sandbox checks"
SANDBOX_STATUS=$(openshell sandbox list 2>/dev/null | grep "$SANDBOX_NAME" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $NF}' || echo "")
if [ "$SANDBOX_STATUS" = "Ready" ]; then
    info "PASS: Sandbox '$SANDBOX_NAME' is Ready"
    PASSED=$((PASSED + 1))
else
    error "FAIL: Sandbox '$SANDBOX_NAME' status: ${SANDBOX_STATUS:-not found}"
    FAILED=$((FAILED + 1))
fi

step "Claude Code in sandbox"
CLAUDE_VER=$(openshell sandbox exec --name "$SANDBOX_NAME" -- /sandbox/.npm-global/bin/claude --version 2>&1 | grep -v "Using sandbox" || echo "")
if echo "$CLAUDE_VER" | grep -q "Claude Code"; then
    info "PASS: Claude Code installed ($CLAUDE_VER)"
    PASSED=$((PASSED + 1))
else
    error "FAIL: Claude Code not found in sandbox"
    FAILED=$((FAILED + 1))
fi

step "LiteLLM Anthropic API from sandbox (model: ${LITELLM_MODEL:-gpt-oss-120b})"
if [ -n "${LITELLM_API_KEY:-}" ] && [ -n "${LITELLM_BASE_URL:-}" ]; then
    BASE="${LITELLM_BASE_URL%/v1}"
    HTTP_CODE=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE}/v1/messages" -H "x-api-key: ${LITELLM_API_KEY}" -H "Content-Type: application/json" -H "anthropic-version: 2023-06-01" -d '{"model":"'"${LITELLM_MODEL:-gpt-oss-120b}"'","max_tokens":5,"messages":[{"role":"user","content":"ok"}]}' 2>&1 | grep -v "Using sandbox")
    if [ "$HTTP_CODE" = "200" ]; then
        info "PASS: LiteLLM Anthropic API (HTTP 200)"
        PASSED=$((PASSED + 1))
    else
        error "FAIL: LiteLLM Anthropic API (HTTP $HTTP_CODE)"
        FAILED=$((FAILED + 1))
    fi
else
    info "SKIP: LiteLLM (no .env credentials)"
fi

step "RHOAI MLflow checks"
OCP_TOKEN=$(oc whoami -t 2>/dev/null || true)
if [ -n "$OCP_TOKEN" ]; then
    MLF_URI="${MLFLOW_TRACKING_URI:-https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow}"
    MLF_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $OCP_TOKEN" "${MLF_URI}/health" 2>/dev/null)
    if [ "$MLF_CODE" = "200" ]; then
        info "PASS: RHOAI MLflow health (HTTP 200)"
        PASSED=$((PASSED + 1))
    else
        error "FAIL: RHOAI MLflow health (HTTP $MLF_CODE)"
        FAILED=$((FAILED + 1))
    fi
else
    info "SKIP: RHOAI MLflow (no OCP token)"
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
