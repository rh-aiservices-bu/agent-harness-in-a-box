#!/bin/bash
# Setup a Hermes agent sandbox with LiteLLM inference and optional RHOAI MLflow tracing.
# Requires OpenShell gateway already deployed (via install.sh or Demo 2).
#
# Usage:
#   bash setup-sandbox.sh [sandbox-name]
#
# Environment:
#   SANDBOX_IMAGE  - Pre-baked image URL. When set, creates sandbox with --from
#                    and skips runtime install. Example:
#                    SANDBOX_IMAGE=quay.io/rcarrata/hermes-sandbox:latest bash setup-sandbox.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

SANDBOX_NAME="${1:-hermes-demo}"

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

MLFLOW_SANDBOX_URI="https://mlflow-redhat-ods-applications.${OCP_APPS_DOMAIN}"

step "Render network policy (tier: ${POLICY_TIER:-standard})"
POLICY_TIER="${POLICY_TIER:-standard}"
POLICY_TEMPLATE="$SCRIPT_DIR/config/policy-${POLICY_TIER}.yaml.template"
if [ ! -f "$POLICY_TEMPLATE" ] && [ -f "$SCRIPT_DIR/config/policy-${POLICY_TIER}.yaml" ]; then
    POLICY_TEMPLATE="$SCRIPT_DIR/config/policy-${POLICY_TIER}.yaml"
fi
RENDERED_POLICY="/tmp/policy-${POLICY_TIER}-rendered.yaml"
if [[ "$POLICY_TEMPLATE" == *.template ]]; then
    render_policy "$POLICY_TEMPLATE" "$RENDERED_POLICY" "$OCP_APPS_DOMAIN"
else
    cp "$POLICY_TEMPLATE" "$RENDERED_POLICY"
fi

step "Register LiteLLM provider"
openshell provider delete litellm 2>/dev/null || true
openshell provider create \
    --name litellm \
    --type openai \
    --credential "OPENAI_API_KEY=${LITELLM_API_KEY}" \
    --config "base_url=${LITELLM_BASE_URL}"

step "Configure inference routing (optional)"
openshell inference set --provider litellm --model "${LITELLM_MODEL:-gemini-2.5-pro}" --no-verify 2>/dev/null \
    && info "User inference route set" \
    || warn "inference set not supported by this gateway version - Hermes uses direct OPENAI_BASE_URL"
openshell inference set --provider litellm --model "${LITELLM_MODEL_SMALL:-llama-scout-17b}" --system --no-verify 2>/dev/null \
    && info "System inference route set" \
    || true

step "Create sandbox: $SANDBOX_NAME"
openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
sleep 3
CREATE_ARGS=(--name "$SANDBOX_NAME" --policy "$RENDERED_POLICY" --no-tty)
if [ -n "${SANDBOX_IMAGE:-}" ]; then
    info "Using pre-baked image: $SANDBOX_IMAGE"
    CREATE_ARGS+=(--from "$SANDBOX_IMAGE")
fi
openshell sandbox create "${CREATE_ARGS[@]}" -- echo "sandbox created" 2>&1 || true

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

step "Apply network policy (tier: $POLICY_TIER)"
openshell policy set --policy "$RENDERED_POLICY" --wait "$SANDBOX_NAME"

if [ -z "${SANDBOX_IMAGE:-}" ]; then
    step "Install Hermes agent in sandbox"
    openshell sandbox exec --name "$SANDBOX_NAME" -- bash -c '
        pip3 install --user --no-cache-dir hermes-agent 2>&1 | tail -5
        export PATH="/sandbox/.local/bin:$PATH"
        hermes --version
    '
else
    step "Verify Hermes agent in sandbox"
    openshell sandbox exec --name "$SANDBOX_NAME" -- hermes --version
fi

step "Upload Hermes config"
sed -e "s|\${LITELLM_BASE_URL}|${LITELLM_BASE_URL}|g" \
    -e "s|\${LITELLM_API_KEY}|${LITELLM_API_KEY}|g" \
    -e "s|\${LITELLM_MODEL}|${LITELLM_MODEL:-gemini-2.5-pro}|g" \
    "$SCRIPT_DIR/config/hermes-config.yaml.template" > /tmp/hermes-config.yaml
openshell sandbox exec --name "$SANDBOX_NAME" -- mkdir -p /sandbox/.hermes
openshell sandbox upload "$SANDBOX_NAME" /tmp/hermes-config.yaml /sandbox/.hermes/config.yaml

step "Upload environment init script"
cat > /tmp/sandbox-init.sh << INITHEADER
#!/bin/sh
LITELLM_API_KEY="${LITELLM_API_KEY}"
LITELLM_BASE_URL="${LITELLM_BASE_URL}"
MLFLOW_TRACKING_URI="${MLFLOW_SANDBOX_URI}"
OCP_TOKEN="${OCP_TOKEN}"
MLFLOW_WORKSPACE="${MLFLOW_WORKSPACE:-openshell}"
INITHEADER
cat >> /tmp/sandbox-init.sh << 'INITBODY'

export OPENAI_API_KEY="$LITELLM_API_KEY"
export OPENAI_BASE_URL="$LITELLM_BASE_URL"
export HERMES_HOME="/sandbox/.hermes"
export PATH="/sandbox/.local/bin:$PATH"

# RHOAI MLflow tracing (external route, Bearer token auth)
export MLFLOW_TRACKING_URI="$MLFLOW_TRACKING_URI"
export MLFLOW_TRACKING_TOKEN="$OCP_TOKEN"
export MLFLOW_TRACKING_INSECURE_TLS="true"
export MLFLOW_EXPERIMENT_NAME="hermes-sandbox"
export MLFLOW_WORKSPACE="$MLFLOW_WORKSPACE"

echo ""
echo "=== LiteLLM Model Selector ==="
echo ""
echo "Fetching available models..."

MODELS=$(curl -s "${LITELLM_BASE_URL}/models" -H "Authorization: Bearer ${LITELLM_API_KEY}" 2>/dev/null \
  | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//' | sort)

if [ -z "$MODELS" ]; then
    echo "Could not fetch models. Using default: gemini-2.5-pro"
    SELECTED="gemini-2.5-pro"
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
        echo "Invalid selection. Using default: gemini-2.5-pro"
        SELECTED="gemini-2.5-pro"
    fi
fi

export OPENAI_MODEL="$SELECTED"
echo ""
echo "Model: $SELECTED"
echo "Run: hermes"
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

info "NOTE: Network policy is enforced via the CONNECT proxy when using openshell CLI tools."
info "Direct pod access (oc exec / OCP console) bypasses the sandbox security model."

step "Create MLflow experiment"
if [ -n "$OCP_TOKEN" ]; then
    openshell sandbox exec --name "$SANDBOX_NAME" -- sh -c "export MLFLOW_TRACKING_URI='${MLFLOW_SANDBOX_URI}' MLFLOW_TRACKING_TOKEN='${OCP_TOKEN}' MLFLOW_TRACKING_INSECURE_TLS=true MLFLOW_WORKSPACE='${MLFLOW_WORKSPACE:-openshell}' && python3 -c 'import os, mlflow; mlflow.set_tracking_uri(os.environ[\"MLFLOW_TRACKING_URI\"]); name=\"hermes-sandbox\"; exp=mlflow.get_experiment_by_name(name); print(exp.experiment_id if exp else mlflow.create_experiment(name))' 2>&1 || echo 'MLflow setup: non-fatal'"
    info "MLflow experiment hermes-sandbox created"
else
    warn "MLflow experiment: SKIP (no OCP token)"
fi

step "Test LiteLLM from sandbox"
RESULT=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -s --connect-timeout 10 --max-time 30 -w "\n%{http_code}" -X POST "${LITELLM_BASE_URL}/chat/completions" -H "Authorization: Bearer ${LITELLM_API_KEY}" -H "Content-Type: application/json" -d '{"model":"'"${LITELLM_MODEL:-gemini-2.5-pro}"'","messages":[{"role":"user","content":"Say ok"}],"max_tokens":5}' 2>&1 | grep -v "Using sandbox")
HTTP_CODE=$(echo "$RESULT" | tail -1)
if [ "$HTTP_CODE" = "200" ]; then
    info "LiteLLM test: OK (HTTP 200) - model: ${LITELLM_MODEL:-gemini-2.5-pro}"
else
    warn "LiteLLM test: HTTP $HTTP_CODE"
fi

step "Test RHOAI MLflow from sandbox"
if [ -n "$OCP_TOKEN" ]; then
    MLF_CODE=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -sk --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${OCP_TOKEN}" -H "X-Mlflow-Workspace: ${MLFLOW_WORKSPACE:-openshell}" "${MLFLOW_SANDBOX_URI}/api/2.0/mlflow/experiments/search?max_results=1" 2>&1 | grep -v "Using sandbox" || echo "000")
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
echo "   hermes                    # interactive CLI"
echo "   hermes gateway run        # gateway mode (port 8787)"
echo ""
echo " Model: ${LITELLM_MODEL:-gemini-2.5-pro}"
echo " MLflow: ${MLFLOW_SANDBOX_URI}"
echo ""
