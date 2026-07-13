#!/bin/bash
# Pre-flight check for agent-harness-in-a-box demos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=functions.sh
source "$SCRIPT_DIR/functions.sh"

echo "============================================"
echo " Agent Harness in a Box - Pre-flight Check"
echo "============================================"
echo ""

check_prereqs

echo ""
info "Cluster: $(oc whoami --show-server)"
info "User:    $(oc whoami)"
info "Domain:  $(detect_apps_domain)"
echo ""

# Check for openshell CLI
if command -v openshell &>/dev/null; then
    info "openshell CLI: $(openshell --version 2>/dev/null || echo 'installed')"
else
    warn "openshell CLI not found. Install from: https://docs.nvidia.com/openshell/latest/install"
fi

# Check storage
if oc get storageclass -o name 2>/dev/null | grep -q .; then
    info "StorageClass: $(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo 'available')"
else
    error "No StorageClass found. OpenShell gateway requires a 1Gi PVC."
fi

echo ""
info "All checks passed. Ready to run demos."
