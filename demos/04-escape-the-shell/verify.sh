#!/bin/bash
# Verify Demo 4: Check that gateway, CTF UI, and sandbox are running.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

NAMESPACE="${NAMESPACE:-openshell-ctf}"
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
echo " Verify Demo 4: Escape the Shell"
echo "============================================"
echo ""

check "Agent Sandbox CRD exists" oc get crd sandboxes.agents.x-k8s.io
check "Namespace exists" oc get ns "$NAMESPACE"
check "Gateway pod running" oc -n "$NAMESPACE" wait --for=condition=Ready pod -l app.kubernetes.io/name=openshell --timeout=10s
check "Gateway service exists" oc -n "$NAMESPACE" get svc openshell
check "Gateway route exists" oc -n "$NAMESPACE" get route openshell-gw
check "CTF UI deployment running" oc -n "$NAMESPACE" wait --for=condition=Available deployment/ctf-ui --timeout=10s
check "CTF UI service exists" oc -n "$NAMESPACE" get svc ctf-ui
check "CTF UI route exists" oc -n "$NAMESPACE" get route ctf-ui
check "Policy ConfigMap exists" oc -n "$NAMESPACE" get configmap ctf-policies

GW_ROUTE=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$GW_ROUTE" ]; then
    check "Gateway reachable via Route" curl -s --max-time 5 -o /dev/null -w '' "http://$GW_ROUTE"
fi

CTF_ROUTE=$(oc -n "$NAMESPACE" get route ctf-ui -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$CTF_ROUTE" ]; then
    check "CTF UI reachable (health)" curl -s --max-time 5 -o /dev/null -w '' "https://$CTF_ROUTE/health"
fi

# Check sandbox if openshell CLI is available
if command -v openshell &>/dev/null; then
    SANDBOX_STATUS=$(openshell sandbox list 2>/dev/null | grep "ctf-sandbox" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $NF}' || echo "")
    if [ "$SANDBOX_STATUS" = "Ready" ]; then
        info "PASS: CTF sandbox is Ready"
        PASSED=$((PASSED + 1))
    else
        warn "CTF sandbox not ready (status: $SANDBOX_STATUS). Run setup-sandbox.sh"
    fi
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
