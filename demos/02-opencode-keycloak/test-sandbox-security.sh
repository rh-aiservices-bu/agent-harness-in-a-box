#!/bin/bash
# Test OpenShell sandbox security enforcement (standard policy).
# Demonstrates: network allowlisting, L7 read-only enforcement, Landlock.
#
# Usage:
#   bash test-sandbox-security.sh [sandbox-name]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

SANDBOX_NAME="${1:-opencode-demo}"

export PATH="$HOME/bin:$PATH"

if [ -f "$REPO_ROOT/.env" ]; then
    source "$REPO_ROOT/.env"
fi
OCP_TOKEN=$(oc whoami -t 2>/dev/null || true)
MLFLOW_SANDBOX_URI="https://mlflow-redhat-ods-applications.${OCP_APPS_DOMAIN:-localhost}"

PASS=0 FAIL=0 TOTAL=0
track() { TOTAL=$((TOTAL + 1)); if [ "$1" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi; }

echo ""
echo "================================================================"
echo " OpenShell Security Test - STANDARD Policy"
echo " Sandbox: $SANDBOX_NAME"
echo "================================================================"

# --- Network: Allowlisting ---
echo ""
step "1. Network Allowlisting"
echo "   Package registries and GitHub (read-only) are allowed."
echo "   Direct AI APIs and arbitrary web access are blocked."
echo ""

test_curl "curl https://registry.npmjs.org/express (npm)" \
    "https://registry.npmjs.org/express" "$SANDBOX_NAME"
track $?

test_curl "curl https://pypi.org/simple/requests/ (PyPI)" \
    "https://pypi.org/simple/requests/" "$SANDBOX_NAME"
track $?

test_curl "curl https://api.anthropic.com (blocked)" \
    "https://api.anthropic.com/v1/models" "$SANDBOX_NAME"
track $?

test_curl "curl https://example.com (blocked)" \
    "https://example.com" "$SANDBOX_NAME"
track $?

test_curl "curl https://opencode.ai (blocked)" \
    "https://opencode.ai" "$SANDBOX_NAME"
track $?

# --- Network: L7 Read-Only ---
echo ""
step "2. L7 Inspection: Read-Only Enforcement"
echo "   GitHub is allowed but restricted to read-only (GET)."
echo "   POST requests are blocked at Layer 7 by the CONNECT proxy."
echo ""

test_curl "GET https://api.github.com/repos/NVIDIA/OpenShell" \
    "https://api.github.com/repos/NVIDIA/OpenShell" "$SANDBOX_NAME"
track $?

test_curl_method "POST https://api.github.com/repos/.../issues" \
    "POST" "https://api.github.com/repos/NVIDIA/OpenShell/issues" "$SANDBOX_NAME"
track $?

test_curl "GET raw.githubusercontent.com (read-only)" \
    "https://raw.githubusercontent.com/NVIDIA/OpenShell/main/README.md" "$SANDBOX_NAME"
track $?

# --- Network: MLflow + OAuth ---
echo ""
step "3. MLflow + OpenShift OAuth"
echo "   RHOAI MLflow and OpenShift OAuth endpoints are allowed."
echo ""

if [ -n "$OCP_TOKEN" ] && [ -n "${OCP_APPS_DOMAIN:-}" ]; then
    test_curl "curl MLflow API (experiments/search)" \
        "${MLFLOW_SANDBOX_URI}/api/2.0/mlflow/experiments/search?max_results=1" "$SANDBOX_NAME"
    track $?
else
    printf "  ${YELLOW}[SKIP]${NC}  %-55s -> no OCP token\n" "MLflow API"
fi

# --- Filesystem: Landlock ---
echo ""
step "4. Landlock: Filesystem Enforcement"
echo ""

test_file_write "write /workspace/test-$$" "/workspace/test-$$" "$SANDBOX_NAME"
track $?

test_file_write "write /tmp/test-$$" "/tmp/test-$$" "$SANDBOX_NAME"
track $?

test_file_write "write /etc/test-$$ (read-only)" "/etc/test-$$" "$SANDBOX_NAME"
track $?

test_file_write "write /usr/test-$$ (read-only)" "/usr/test-$$" "$SANDBOX_NAME"
track $?

test_file_read "read /etc/os-release (read-only)" "/etc/os-release" "$SANDBOX_NAME"
track $?

# --- Process ---
echo ""
step "5. Process Isolation"
echo ""

test_process "whoami" "whoami" "sandbox" "$SANDBOX_NAME"
track $?

# --- Summary ---
echo ""
echo "================================================================"
echo " Results: $PASS passed, $FAIL unexpected out of $TOTAL tests"
echo ""
echo " Network:    Registries + GitHub RO + MLflow allowed"
echo " L7:         GitHub POST blocked (read-only enforcement)"
echo " Filesystem: Landlock restricts to declared paths"
echo " Process:    Running as non-root sandbox user"
echo "================================================================"
echo ""
