#!/bin/bash
# Setup an OpenCode sandbox with LiteLLM inference and RHOAI MLflow tracing.
# Requires Demo 2 infrastructure (Keycloak OIDC) already deployed via install.sh.
#
# Usage:
#   bash setup-sandbox.sh [sandbox-name]
#
# Environment:
#   SANDBOX_IMAGE  - Pre-baked image URL. When set, creates sandbox with --from
#                    and skips runtime install. Example:
#                    SANDBOX_IMAGE=quay.io/rcarrata/agentic-harness-openshell:opencode-v1 bash setup-sandbox.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

SANDBOX_NAME="${1:-opencode-demo}"

if [ ! -f "$REPO_ROOT/.env" ]; then
    error "Missing .env file. Copy .env.example to .env and fill in your credentials."
    exit 1
fi
source "$REPO_ROOT/.env"

if [ -z "${LITELLM_API_KEY:-}" ]; then
    error "LITELLM_API_KEY not set in .env"
    exit 1
fi

export PATH="$HOME/bin:$PATH"

OCP_TOKEN=$(oc whoami -t 2>/dev/null || true)
if [ -z "$OCP_TOKEN" ]; then
    warn "Not logged into OpenShift - MLflow tracing will not work"
fi

step "Apply global network policy"
openshell policy set --global --policy "$SCRIPT_DIR/config/policy.yaml" --yes

step "Register LiteLLM provider"
openshell provider delete litellm 2>/dev/null || true
openshell provider create openai \
    --name litellm \
    --base-url "${LITELLM_BASE_URL}" \
    --api-key "${LITELLM_API_KEY}"

step "Configure inference routing"
openshell inference set --provider litellm --model "${LITELLM_MODEL:-gpt-oss-120b}" --role user
openshell inference set --provider litellm --model "${LITELLM_MODEL_SMALL:-llama-scout-17b}" --role system

step "Create sandbox: $SANDBOX_NAME"
openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
sleep 3
if [ -n "${SANDBOX_IMAGE:-}" ]; then
    info "Using pre-baked image: $SANDBOX_IMAGE"
    openshell sandbox create --name "$SANDBOX_NAME" --from "$SANDBOX_IMAGE"
else
    openshell sandbox create --name "$SANDBOX_NAME"
fi

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

if [ -z "${SANDBOX_IMAGE:-}" ]; then
    step "Install OpenCode in sandbox"
    openshell sandbox exec --name "$SANDBOX_NAME" -- bash -c 'mkdir -p /sandbox/.npm-global && export npm_config_prefix=/sandbox/.npm-global && npm install -g opencode-ai 2>&1 | tail -3'
else
    step "Verify OpenCode in sandbox"
    openshell sandbox exec --name "$SANDBOX_NAME" -- opencode --version
fi

step "Upload OpenCode config"
sed "s|\${LITELLM_BASE_URL}|${LITELLM_BASE_URL}|g" "$SCRIPT_DIR/config/opencode-config.json" > /tmp/opencode.jsonc
openshell sandbox exec --name "$SANDBOX_NAME" -- mkdir -p /sandbox/.config/opencode
openshell sandbox upload "$SANDBOX_NAME" /tmp/opencode.jsonc /sandbox/.config/opencode/opencode.jsonc

step "Upload environment init script"
cat > /tmp/sandbox-init.sh << INITHEADER
#!/bin/sh
LITELLM_API_KEY="${LITELLM_API_KEY}"
LITELLM_BASE_URL="${LITELLM_BASE_URL}"
MLFLOW_TRACKING_URI="${MLFLOW_TRACKING_URI}"
OCP_TOKEN="${OCP_TOKEN}"
MLFLOW_WORKSPACE="${MLFLOW_WORKSPACE:-openshell}"
INITHEADER
cat >> /tmp/sandbox-init.sh << 'INITBODY'

export OPENAI_API_KEY="$LITELLM_API_KEY"
export OPENAI_BASE_URL="$LITELLM_BASE_URL"

# Load OpenCode config (custom provider, model routing, enabled_providers)
if [ -f /sandbox/.config/opencode/opencode.jsonc ]; then
    export OPENCODE_CONFIG_CONTENT=$(cat /sandbox/.config/opencode/opencode.jsonc)
fi

# RHOAI MLflow tracing
export MLFLOW_TRACKING_URI="$MLFLOW_TRACKING_URI"
export MLFLOW_TRACKING_TOKEN="$OCP_TOKEN"
export MLFLOW_EXPERIMENT_NAME="opencode-sandbox"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer ${OCP_TOKEN},X-Mlflow-Workspace=${MLFLOW_WORKSPACE}"

export npm_config_prefix=/sandbox/.npm-global
export PATH="/sandbox/.npm-global/bin:$PATH"

echo ""
echo "=== LiteLLM Model Selector ==="
echo ""
echo "Fetching available models..."

MODELS=$(curl -s "${LITELLM_BASE_URL}/models" -H "Authorization: Bearer ${LITELLM_API_KEY}" 2>/dev/null \
  | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//' | sort)

if [ -z "$MODELS" ]; then
    echo "Could not fetch models. Using default: gpt-oss-120b"
    SELECTED="gpt-oss-120b"
else
    i=1
    for m in $MODELS; do
        echo "  $i) $m"
        i=$((i + 1))
    done
    echo ""
    printf "Select model [1]: "
    read choice
    if [ -z "$choice" ]; then choice=1; fi
    i=1
    SELECTED=""
    for m in $MODELS; do
        if [ "$i" = "$choice" ]; then SELECTED="$m"; break; fi
        i=$((i + 1))
    done
    if [ -z "$SELECTED" ]; then
        echo "Invalid selection. Using default: gpt-oss-120b"
        SELECTED="gpt-oss-120b"
    fi
fi

export OPENAI_MODEL="$SELECTED"
echo ""
echo "Model: $SELECTED"
echo "Run: opencode"
echo ""
INITBODY
openshell sandbox upload "$SANDBOX_NAME" /tmp/sandbox-init.sh /sandbox/.sandbox-init.sh

step "Auto-source environment on login"
openshell sandbox exec --name "$SANDBOX_NAME" -- sh -c '
    grep -q "sandbox-init.sh" /sandbox/.profile 2>/dev/null || \
    cat >> /sandbox/.profile << '"'"'PROFILE'"'"'

# Auto-load sandbox credentials
if [ -f /sandbox/.sandbox-init.sh ] && [ -z "$SANDBOX_ENV_LOADED" ]; then
    . /sandbox/.sandbox-init.sh
    export SANDBOX_ENV_LOADED=1
fi
PROFILE
'

step "Test LiteLLM from sandbox"
RESULT=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -s -w "\n%{http_code}" -X POST "${LITELLM_BASE_URL}/chat/completions" -H "Authorization: Bearer ${LITELLM_API_KEY}" -H "Content-Type: application/json" -d '{"model":"'"${LITELLM_MODEL:-gpt-oss-120b}"'","messages":[{"role":"user","content":"Say ok"}],"max_tokens":5}' 2>&1 | grep -v "Using sandbox")
HTTP_CODE=$(echo "$RESULT" | tail -1)
if [ "$HTTP_CODE" = "200" ]; then
    info "LiteLLM test: OK (HTTP 200) - model: ${LITELLM_MODEL:-gpt-oss-120b}"
else
    warn "LiteLLM test: HTTP $HTTP_CODE"
fi

step "Test RHOAI MLflow from sandbox"
if [ -n "$OCP_TOKEN" ]; then
    MLF_CODE=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${OCP_TOKEN}" -H "X-Mlflow-Workspace: ${MLFLOW_WORKSPACE:-openshell}" "${MLFLOW_TRACKING_URI:-https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow}/api/2.0/mlflow/experiments/search?max_results=1" 2>&1 | grep -v "Using sandbox")
    if [ "$MLF_CODE" = "200" ]; then
        info "RHOAI MLflow test: OK (HTTP 200)"
    else
        warn "RHOAI MLflow test: HTTP $MLF_CODE"
    fi
else
    warn "RHOAI MLflow test: SKIP (no OCP token)"
fi

echo ""
echo "============================================"
echo " Sandbox '$SANDBOX_NAME' ready!"
echo "============================================"
echo ""
echo " Connect with:"
echo "   openshell sandbox connect $SANDBOX_NAME"
echo ""
echo " Inside the sandbox (credentials auto-loaded):"
echo "   opencode"
echo ""
echo " Model: ${LITELLM_MODEL:-gpt-oss-120b}"
echo " MLflow: ${MLFLOW_TRACKING_URI:-https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow}"
echo ""
