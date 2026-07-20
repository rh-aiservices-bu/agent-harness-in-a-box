#!/bin/bash
# Test CTF sandbox security enforcement (strict policy).
# CLI-based validation of all 5 CTF challenge areas.
#
# Usage:
#   bash test-sandbox-security.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

SANDBOX_NAME="ctf-sandbox"

export PATH="$HOME/bin:$PATH"

LITELLM_URL="https://maas-rhdp.apps.maas.redhatworkshops.io"

PASS=0 FAIL=0 TOTAL=0
track() { TOTAL=$((TOTAL + 1)); if [ "$1" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi; }

echo ""
echo "================================================================"
echo " Escape the Shell - CTF Security Tests (STRICT Policy)"
echo " Sandbox: $SANDBOX_NAME"
echo "================================================================"

# --- Challenge 1: Network Default-Deny ---
echo ""
step "Challenge 1: Data Exfiltration (Network Default-Deny)"
echo "   The CONNECT proxy blocks all outbound traffic not in policy."
echo ""

test_curl "curl https://httpbin.org (not in policy)" "https://httpbin.org/get" "$SANDBOX_NAME"
track $?

test_curl "curl https://google.com (not in policy)" "https://google.com" "$SANDBOX_NAME"
track $?

# --- Challenge 2: Binary Binding ---
echo ""
step "Challenge 2: Tool Smuggling (Binary Binding)"
echo "   Inference endpoint allows python3 only, not curl."
echo ""

test_curl "curl \$LITELLM_URL (curl blocked)" "${LITELLM_URL}/health" "$SANDBOX_NAME"
track $?

test_python_url "python3 to \$LITELLM_URL (allowed)" "${LITELLM_URL}/health" "$SANDBOX_NAME"
track $?

# --- Challenge 3: Landlock Filesystem ---
echo ""
step "Challenge 3: Filesystem Escape (Landlock LSM)"
echo "   Landlock restricts filesystem access at the kernel level."
echo ""

test_file_write "write /var/tmp/test (not in policy)" "/var/tmp/test-$$" "$SANDBOX_NAME"
track $?

test_file_write "write /dev/shm/test (not in policy)" "/dev/shm/test-$$" "$SANDBOX_NAME"
track $?

test_file_write "write /tmp/test (allowed)" "/tmp/test-$$" "$SANDBOX_NAME"
track $?

test_file_read "read /etc/os-release (read-only)" "/etc/os-release" "$SANDBOX_NAME"
track $?

# --- Challenge 4: L7 Read-Only ---
echo ""
step "Challenge 4: API Abuse (L7 Read-Only Enforcement)"
echo "   GitHub API is read-only: GET allowed, POST/DELETE blocked."
echo ""

test_curl "GET https://api.github.com/zen (read)" "https://api.github.com/zen" "$SANDBOX_NAME"
track $?

echo "   Testing POST to api.github.com..."
POST_OUTPUT=$(openshell sandbox exec --name "$SANDBOX_NAME" -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
    https://api.github.com/repos/test/test/issues 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
if echo "$POST_OUTPUT" | grep -qE "403|blocked|denied"; then
    info "PASS: POST blocked by L7 policy (got: $POST_OUTPUT)"
    track 0
else
    error "FAIL: POST not blocked (got: $POST_OUTPUT)"
    track 1
fi

# --- Challenge 5: Policy Hot-Reload ---
echo ""
step "Challenge 5: Live Lockdown (Policy Hot-Reload)"
echo "   Verifying httpbin blocked under strict, allowed under permissive."
echo ""

echo "   Phase 1: Strict policy (httpbin should be blocked)..."
test_curl "curl https://httpbin.org (strict)" "https://httpbin.org/get" "$SANDBOX_NAME"
track $?

echo "   Phase 2: Switching to permissive policy..."
openshell policy set --policy "$SCRIPT_DIR/config/policy-ctf-permissive.yaml" --wait "$SANDBOX_NAME"
sleep 2

PERMISSIVE_OUTPUT=$(openshell sandbox exec --name "$SANDBOX_NAME" -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://httpbin.org/get 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
if echo "$PERMISSIVE_OUTPUT" | grep -qE "200"; then
    info "PASS: httpbin allowed under permissive policy (got: $PERMISSIVE_OUTPUT)"
    track 0
else
    error "FAIL: httpbin still blocked under permissive (got: $PERMISSIVE_OUTPUT)"
    track 1
fi

echo "   Phase 3: Restoring strict policy..."
openshell policy set --policy "$SCRIPT_DIR/config/policy-ctf-strict.yaml" --wait "$SANDBOX_NAME"
sleep 2

test_curl "curl https://httpbin.org (strict again)" "https://httpbin.org/get" "$SANDBOX_NAME"
track $?

# --- Summary ---
echo ""
echo "================================================================"
echo " Results: $PASS passed, $FAIL unexpected out of $TOTAL tests"
echo ""
echo " Challenge 1: Network Default-Deny"
echo " Challenge 2: Binary Binding"
echo " Challenge 3: Landlock Filesystem"
echo " Challenge 4: L7 Read-Only"
echo " Challenge 5: Policy Hot-Reload"
echo "================================================================"
echo ""
