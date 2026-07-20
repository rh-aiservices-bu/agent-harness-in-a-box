#!/bin/bash
# Create the CTF sandbox with strict policy for the Escape the Shell demo.
#
# Usage:
#   bash setup-sandbox.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

NAMESPACE="${NAMESPACE:-openshell-ctf}"
SANDBOX_NAME="ctf-sandbox"

export PATH="$HOME/bin:$PATH"

GW_ROUTE=$(oc -n "$NAMESPACE" get route openshell-gw -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$GW_ROUTE" ]; then
    error "Gateway route not found. Run install.sh first."
    exit 1
fi

step "Register gateway with CLI"
openshell gateway add "http://$GW_ROUTE" --local --name openshift 2>/dev/null || info "Gateway already registered"

step "Delete existing sandbox (if any)"
openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
sleep 3

step "Create sandbox: $SANDBOX_NAME"
openshell sandbox create --name "$SANDBOX_NAME" --policy "$SCRIPT_DIR/config/policy-ctf-strict.yaml"

step "Wait for sandbox to be ready"
for i in $(seq 1 30); do
    STATUS=$(openshell sandbox list 2>/dev/null | grep "$SANDBOX_NAME" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $NF}')
    if [ "$STATUS" = "Ready" ]; then
        info "Sandbox is Ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        error "Sandbox did not become Ready within 150s"
        exit 1
    fi
    sleep 5
done

step "Apply strict network policy"
openshell policy set --policy "$SCRIPT_DIR/config/policy-ctf-strict.yaml" --wait "$SANDBOX_NAME"

step "Verify sandbox"
openshell sandbox exec --name "$SANDBOX_NAME" -- whoami
openshell sandbox exec --name "$SANDBOX_NAME" -- cat /etc/os-release | head -2

CTF_ROUTE=$(oc -n "$NAMESPACE" get route ctf-ui -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")

echo ""
echo "============================================"
echo " CTF Sandbox '$SANDBOX_NAME' ready!"
echo "============================================"
echo ""
echo " Open the CTF UI:"
echo "   https://$CTF_ROUTE"
echo ""
echo " Policy: STRICT (inference-only, binary-bound)"
echo " Challenges: 5 flags to capture"
echo ""
echo " CLI validation:"
echo "   bash $SCRIPT_DIR/test-sandbox-security.sh"
echo ""
