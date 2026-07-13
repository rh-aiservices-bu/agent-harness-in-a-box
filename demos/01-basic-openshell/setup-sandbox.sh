#!/bin/bash
# Create a basic sandbox with strict policy for security testing.
# No agent is installed - this creates a bare sandbox to demonstrate
# OpenShell's security enforcement (network, filesystem, process).
#
# Usage:
#   bash setup-sandbox.sh [sandbox-name]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

SANDBOX_NAME="${1:-basic-sandbox}"

export PATH="$HOME/bin:$PATH"

step "Create sandbox: $SANDBOX_NAME"
openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
sleep 3
openshell sandbox create --name "$SANDBOX_NAME" --policy "$SCRIPT_DIR/config/policy-strict.yaml"

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
openshell policy set --policy "$SCRIPT_DIR/config/policy-strict.yaml" --wait "$SANDBOX_NAME"

step "Verify sandbox"
openshell sandbox exec --name "$SANDBOX_NAME" -- whoami
openshell sandbox exec --name "$SANDBOX_NAME" -- cat /etc/os-release | head -2

echo ""
echo "============================================"
echo " Sandbox '$SANDBOX_NAME' ready!"
echo "============================================"
echo ""
echo " Connect: openshell sandbox connect $SANDBOX_NAME"
echo " Test:    bash test-sandbox-security.sh $SANDBOX_NAME"
echo ""
echo " Policy: STRICT (inference-only, binary-bound)"
echo ""
