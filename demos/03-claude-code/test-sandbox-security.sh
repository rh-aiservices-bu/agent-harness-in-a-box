#!/bin/bash
# Test OpenShell sandbox security enforcement (permissive policy).
# Demonstrates: full development access, hot-reload policy switching, Landlock.
#
# Usage:
#   bash test-sandbox-security.sh [sandbox-name]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

SANDBOX_NAME="${1:-claude-demo}"

export PATH="$HOME/bin:$PATH"

if [ -f "$REPO_ROOT/.env" ]; then
    source "$REPO_ROOT/.env"
fi

PASS=0 FAIL=0 TOTAL=0
track() { TOTAL=$((TOTAL + 1)); if [ "$1" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi; }

echo ""
echo "================================================================"
echo " OpenShell Security Test - PERMISSIVE Policy"
echo " Sandbox: $SANDBOX_NAME"
echo "================================================================"

# --- Network: Full Development Access ---
echo ""
step "1. Full Development Access"
echo "   AI APIs, GitHub (full), and registries are allowed."
echo "   Unrecognized hosts are still blocked by the allowlist."
echo ""

test_curl "curl https://api.github.com/repos/NVIDIA/OpenShell (GET)" \
    "https://api.github.com/repos/NVIDIA/OpenShell" "$SANDBOX_NAME"
track $?

test_curl_method "POST https://api.github.com/repos/.../issues" \
    "POST" "https://api.github.com/repos/NVIDIA/OpenShell/issues" "$SANDBOX_NAME"
track $?

test_curl "curl https://api.anthropic.com/v1/models (AI API)" \
    "https://api.anthropic.com/v1/models" "$SANDBOX_NAME"
track $?

test_curl "curl https://registry.npmjs.org/express (npm)" \
    "https://registry.npmjs.org/express" "$SANDBOX_NAME"
track $?

test_curl "curl https://example.com (still blocked!)" \
    "https://example.com" "$SANDBOX_NAME"
track $?

test_curl "curl https://evil-exfil.example.net (blocked)" \
    "https://evil-exfil.example.net" "$SANDBOX_NAME"
track $?

# --- Hot-Reload Demo ---
echo ""
step "2. Hot-Reload: Switch to Strict Policy"
echo "   Network policies are dynamic - hot-reload via the CONNECT proxy"
echo "   without restarting the sandbox."
echo ""

STRICT_POLICY="$REPO_ROOT/demos/01-basic-openshell/config/policy-strict.yaml"
if [ -f "$STRICT_POLICY" ]; then
    info "Applying strict policy (live switch)..."
    openshell policy set --policy "$STRICT_POLICY" --wait "$SANDBOX_NAME" 2>/dev/null

    test_curl "curl https://api.github.com (was 200, now strict)" \
        "https://api.github.com/repos/NVIDIA/OpenShell" "$SANDBOX_NAME"
    track $?

    test_curl "curl https://registry.npmjs.org (was 200, now strict)" \
        "https://registry.npmjs.org/express" "$SANDBOX_NAME"
    track $?

    echo ""
    info "Restoring permissive policy..."
    OCP_APPS_DOMAIN="${OCP_APPS_DOMAIN:-}"
    PERMISSIVE_TEMPLATE="$SCRIPT_DIR/config/policy-permissive.yaml.template"
    RENDERED="/tmp/policy-permissive-rendered.yaml"
    if [ -n "$OCP_APPS_DOMAIN" ]; then
        render_policy "$PERMISSIVE_TEMPLATE" "$RENDERED" "$OCP_APPS_DOMAIN"
    else
        sed "s/__OCP_APPS_DOMAIN__/localhost/g" "$PERMISSIVE_TEMPLATE" > "$RENDERED"
    fi
    openshell policy set --policy "$RENDERED" --wait "$SANDBOX_NAME" 2>/dev/null

    test_curl "curl https://api.github.com (restored to permissive)" \
        "https://api.github.com/repos/NVIDIA/OpenShell" "$SANDBOX_NAME"
    track $?
else
    printf "  ${YELLOW}[SKIP]${NC}  %-55s -> strict policy not found\n" "Hot-reload demo"
fi

# --- Filesystem: Landlock ---
echo ""
step "3. Landlock: Filesystem Enforcement"
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
step "4. Process Isolation"
echo ""

test_process "whoami" "whoami" "sandbox" "$SANDBOX_NAME"
track $?

# --- Summary ---
echo ""
echo "================================================================"
echo " Results: $PASS passed, $FAIL unexpected out of $TOTAL tests"
echo ""
echo " Network:    Wide access but still allowlist-based"
echo " Hot-reload: Policy switches take effect instantly"
echo " Filesystem: Landlock restricts to declared paths"
echo " Process:    Running as non-root sandbox user"
echo "================================================================"
echo ""
