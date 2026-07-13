#!/bin/bash
# Shared functions for agent-harness-in-a-box demos.

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${BLUE}=== $* ===${NC}"; }

check_prereqs() {
    local missing=()
    command -v oc &>/dev/null    || missing+=("oc")
    command -v helm &>/dev/null  || missing+=("helm")
    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing required tools: ${missing[*]}"
        exit 1
    fi
    if ! oc whoami &>/dev/null; then
        error "Not logged in to OpenShift. Run 'oc login' first."
        exit 1
    fi
    info "Prerequisites OK ($(oc whoami) @ $(oc whoami --show-server))"
}

detect_apps_domain() {
    oc get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null
}

wait_for_rollout() {
    local type="$1" name="$2" ns="$3" timeout="${4:-300}"
    info "Waiting for $type/$name in $ns (timeout: ${timeout}s)..."
    oc -n "$ns" rollout status "$type/$name" --timeout="${timeout}s"
}

wait_for_pod_ready() {
    local ns="$1" selector="$2" timeout="${3:-120}"
    info "Waiting for pod ($selector) in $ns..."
    oc -n "$ns" wait --for=condition=Ready pod -l "$selector" --timeout="${timeout}s" 2>/dev/null \
        || warn "Pod not ready yet (may still be pulling image)"
}

_find_openssl() {
    # macOS LibreSSL does not support Ed25519. Use Homebrew OpenSSL if available.
    local brew_ssl
    for p in /opt/homebrew/opt/openssl@3/bin/openssl \
             /opt/homebrew/opt/openssl/bin/openssl \
             /usr/local/opt/openssl@3/bin/openssl \
             /usr/local/opt/openssl/bin/openssl; do
        if [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    # Fallback: system openssl (works on Linux, may fail on macOS)
    echo "openssl"
}

create_jwt_secret() {
    local ns="$1"
    if oc -n "$ns" get secret openshell-jwt-keys &>/dev/null; then
        info "Secret 'openshell-jwt-keys' already exists, skipping"
        return 0
    fi
    info "Generating Ed25519 JWT signing keypair..."
    local OPENSSL tmpdir kid
    OPENSSL=$(_find_openssl)
    info "Using OpenSSL: $($OPENSSL version)"
    tmpdir=$(mktemp -d)
    $OPENSSL genpkey -algorithm Ed25519 -out "$tmpdir/signing.pem" 2>/dev/null
    $OPENSSL pkey -in "$tmpdir/signing.pem" -pubout -out "$tmpdir/public.pem" 2>/dev/null
    kid=$($OPENSSL pkey -in "$tmpdir/signing.pem" -pubout -outform DER 2>/dev/null \
        | $OPENSSL dgst -sha256 -binary | $OPENSSL base64 -A | tr '+/' '-_' | tr -d '=')
    echo "$kid" > "$tmpdir/kid.txt"
    oc -n "$ns" create secret generic openshell-jwt-keys \
        --from-file=signing.pem="$tmpdir/signing.pem" \
        --from-file=public.pem="$tmpdir/public.pem" \
        --from-file=kid="$tmpdir/kid.txt"
    rm -rf "$tmpdir"
    info "JWT signing secret created"
}

install_agent_sandbox_crd() {
    step "Install Agent Sandbox CRD and controller"
    oc apply -f \
        https://github.com/kubernetes-sigs/agent-sandbox/releases/latest/download/manifest.yaml
    wait_for_pod_ready "agent-sandbox-system" "control-plane=controller-manager" 120
}

create_openshell_namespace() {
    local ns="$1"
    step "Create namespace $ns"
    oc create ns "$ns" --dry-run=client -o yaml | oc apply -f -
}

grant_privileged_scc() {
    local ns="$1"
    step "Grant privileged SCC to openshell-sandbox SA"
    oc adm policy add-scc-to-user privileged -z openshell-sandbox -n "$ns"
}

render_policy() {
    local template="$1" output="$2" domain="$3"
    if [ ! -f "$template" ]; then
        error "Policy template not found: $template"
        exit 1
    fi
    if [ -z "$domain" ]; then
        error "OCP_APPS_DOMAIN required to render policy"
        exit 1
    fi
    sed "s/__OCP_APPS_DOMAIN__/${domain}/g" "$template" > "$output"
    info "Policy rendered from $(basename "$template") (domain: $domain)"
}

# --- Security test helpers ---

_sandbox_exec() {
    local sandbox="$1"; shift
    openshell sandbox exec --name "$sandbox" -- "$@" 2>&1 | grep -v "Using sandbox"
}

test_curl() {
    local label="$1" url="$2" sandbox="$3"
    local raw code connect_code
    raw=$(_sandbox_exec "$sandbox" curl -s -o /dev/null -w '%{http_code}:%{http_connect}' --max-time 10 "$url" | tail -1)
    code="${raw%%:*}"
    connect_code="${raw##*:}"
    if [ "$code" = "200" ] || [ "$code" = "401" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
        printf "  ${GREEN}[ALLOWED]${NC} %-55s -> HTTP %s\n" "$label" "$code"
        return 0
    elif [ "$connect_code" = "403" ]; then
        printf "  ${RED}[BLOCKED]${NC} %-55s -> CONNECT 403 (proxy denied)\n" "$label"
        return 1
    else
        printf "  ${RED}[BLOCKED]${NC} %-55s -> HTTP %s\n" "$label" "${code:-ERR}"
        return 1
    fi
}

test_curl_method() {
    local label="$1" method="$2" url="$3" sandbox="$4"
    local code
    code=$(_sandbox_exec "$sandbox" curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X "$method" "$url" | tail -1)
    if [ "$code" = "200" ] || [ "$code" = "401" ] || [ "$code" = "404" ] || [ "$code" = "422" ]; then
        printf "  ${GREEN}[ALLOWED]${NC} %-55s -> HTTP %s\n" "$label" "$code"
        return 0
    else
        printf "  ${RED}[BLOCKED]${NC} %-55s -> HTTP %s\n" "$label" "${code:-ERR}"
        return 1
    fi
}

test_python_url() {
    local label="$1" url="$2" sandbox="$3"
    local result
    result=$(_sandbox_exec "$sandbox" python3 -c "
import urllib.request, ssl
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    r = urllib.request.urlopen('$url', timeout=10, context=ctx)
    print(r.status)
except Exception as e:
    print('ERR: ' + str(e)[:60])
" | tail -1)
    if echo "$result" | grep -qE '^(200|301|302|401)$'; then
        printf "  ${GREEN}[ALLOWED]${NC} %-55s -> HTTP %s\n" "$label" "$result"
        return 0
    else
        printf "  ${RED}[BLOCKED]${NC} %-55s -> %s\n" "$label" "${result:-ERR}"
        return 1
    fi
}

test_file_write() {
    local label="$1" path="$2" sandbox="$3"
    local result
    result=$(_sandbox_exec "$sandbox" sh -c "touch ${path} 2>&1 && echo WRITE_OK || echo WRITE_FAIL" | tail -1)
    if [ "$result" = "WRITE_OK" ]; then
        printf "  ${GREEN}[ALLOWED]${NC} %-55s -> OK\n" "$label"
        _sandbox_exec "$sandbox" rm -f "$path" >/dev/null 2>&1 || true
        return 0
    else
        printf "  ${RED}[BLOCKED]${NC} %-55s -> Permission denied\n" "$label"
        return 1
    fi
}

test_file_read() {
    local label="$1" path="$2" sandbox="$3"
    local result
    result=$(_sandbox_exec "$sandbox" sh -c "cat ${path} > /dev/null 2>&1 && echo READ_OK || echo READ_FAIL" | tail -1)
    if [ "$result" = "READ_OK" ]; then
        printf "  ${GREEN}[ALLOWED]${NC} %-55s -> OK\n" "$label"
        return 0
    else
        printf "  ${RED}[BLOCKED]${NC} %-55s -> Permission denied\n" "$label"
        return 1
    fi
}

test_process() {
    local label="$1" cmd="$2" expect="$3" sandbox="$4"
    local actual
    actual=$(_sandbox_exec "$sandbox" sh -c "$cmd" | tail -1)
    if [ "$actual" = "$expect" ]; then
        printf "  ${GREEN}[VERIFY]${NC}  %-55s -> %s\n" "$label" "$actual"
        return 0
    else
        printf "  ${YELLOW}[CHECK]${NC}  %-55s -> %s (expected: %s)\n" "$label" "$actual" "$expect"
        return 1
    fi
}
