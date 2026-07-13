#!/bin/bash
# Setup a Claude Code sandbox with LiteLLM and RHOAI MLflow.
# Requires Demo 2 (Keycloak OIDC) already deployed.
#
# Usage:
#   bash setup-sandbox.sh [sandbox-name]
#
# Environment:
#   SANDBOX_IMAGE  - Pre-baked image URL. When set, creates sandbox with --from
#                    and skips runtime install. Example:
#                    SANDBOX_IMAGE=quay.io/rcarrata/agentic-harness-openshell:claude-code-v1 bash setup-sandbox.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/common/functions.sh"

SANDBOX_NAME="${1:-claude-demo}"

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

# Sandbox-accessible MLflow URI (external route, not internal svc)
MLFLOW_SANDBOX_URI="https://mlflow-redhat-ods-applications.${OCP_APPS_DOMAIN}"

step "Render network policy (tier: ${POLICY_TIER:-permissive})"
POLICY_TIER="${POLICY_TIER:-permissive}"
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

step "Create sandbox: $SANDBOX_NAME"
openshell sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
sleep 3
if [ -n "${SANDBOX_IMAGE:-}" ]; then
    info "Using pre-baked image: $SANDBOX_IMAGE"
    openshell sandbox create --name "$SANDBOX_NAME" --from "$SANDBOX_IMAGE" --policy "$RENDERED_POLICY"
else
    openshell sandbox create --name "$SANDBOX_NAME" --policy "$RENDERED_POLICY"
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

step "Apply network policy (tier: $POLICY_TIER)"
openshell policy set --policy "$RENDERED_POLICY" --wait "$SANDBOX_NAME"

if [ -z "${SANDBOX_IMAGE:-}" ]; then
    step "Install Claude Code in sandbox"
    cat > /tmp/install-claude-code.sh << 'INSTALL'
#!/bin/bash
set -e
mkdir -p /sandbox/.npm-global/bin
cd /tmp
curl -sL -o claude-code-linux-x64.tgz "https://registry.npmjs.org/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-2.1.206.tgz"
tar xzf claude-code-linux-x64.tgz
cp package/claude /sandbox/.npm-global/bin/claude
chmod +x /sandbox/.npm-global/bin/claude
rm -rf package claude-code-linux-x64.tgz
export PATH="/sandbox/.npm-global/bin:$PATH"
claude --version
INSTALL
    openshell sandbox upload "$SANDBOX_NAME" /tmp/install-claude-code.sh /tmp/install-claude-code.sh
    openshell sandbox exec --name "$SANDBOX_NAME" -- bash /tmp/install-claude-code.sh
else
    step "Verify Claude Code in sandbox"
    openshell sandbox exec --name "$SANDBOX_NAME" -- claude --version
fi

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

export ANTHROPIC_API_KEY="$LITELLM_API_KEY"
export ANTHROPIC_BASE_URL="${LITELLM_BASE_URL%/v1}"

# RHOAI MLflow tracing (external route, Bearer token auth)
export MLFLOW_TRACKING_URI="$MLFLOW_TRACKING_URI"
export MLFLOW_TRACKING_TOKEN="$OCP_TOKEN"
export MLFLOW_TRACKING_INSECURE_TLS="true"
export MLFLOW_EXPERIMENT_NAME="claude-code-sandbox"
export MLFLOW_WORKSPACE="$MLFLOW_WORKSPACE"

export PATH="/sandbox/.local/bin:/sandbox/.npm-global/bin:$PATH"

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

export ANTHROPIC_MODEL="$SELECTED"
echo ""
echo "Model: $SELECTED"
echo "Run: claude --model $SELECTED"
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

step "Configure MLflow stop-hook"
if [ -n "$OCP_TOKEN" ]; then
    # Patch the pre-baked settings.json with runtime RHOAI tracking URI and token.
    # The plugin structure (settings.local.json) is already correct from build time.
    cat > /tmp/claude-mlflow-settings.json << EOF
{
  "env": {
    "MLFLOW_CLAUDE_TRACING_ENABLED": "true",
    "MLFLOW_TRACKING_URI": "${MLFLOW_SANDBOX_URI}",
    "MLFLOW_TRACKING_TOKEN": "${OCP_TOKEN}",
    "MLFLOW_TRACKING_INSECURE_TLS": "true",
    "MLFLOW_EXPERIMENT_NAME": "claude-code-sandbox",
    "MLFLOW_WORKSPACE": "${MLFLOW_WORKSPACE:-openshell}"
  }
}
EOF
    openshell sandbox upload "$SANDBOX_NAME" /tmp/claude-mlflow-settings.json /tmp/claude-mlflow-settings.json
    openshell sandbox exec --name "$SANDBOX_NAME" -- cp /tmp/claude-mlflow-settings.json /workspace/.claude/settings.json
    info "MLflow stop-hook configured with RHOAI tracking URI"
fi

step "Create MLflow experiment"
if [ -n "$OCP_TOKEN" ]; then
    # mlflow[kubernetes] handles auth natively (Bearer token + X-Mlflow-Workspace header)
    openshell sandbox exec --name "$SANDBOX_NAME" -- sh -c "export MLFLOW_TRACKING_URI='${MLFLOW_SANDBOX_URI}' MLFLOW_TRACKING_TOKEN='${OCP_TOKEN}' MLFLOW_TRACKING_INSECURE_TLS=true MLFLOW_WORKSPACE='${MLFLOW_WORKSPACE:-openshell}' && python3 -c 'import os, mlflow; mlflow.set_tracking_uri(os.environ[\"MLFLOW_TRACKING_URI\"]); name=\"claude-code-sandbox\"; exp=mlflow.get_experiment_by_name(name); print(exp.experiment_id if exp else mlflow.create_experiment(name))' 2>&1 || echo 'MLflow setup: non-fatal'"
    info "MLflow experiment claude-code-sandbox created"
else
    warn "MLflow experiment: SKIP (no OCP token)"
fi

step "Test LiteLLM (Anthropic Messages API)"
RESULT=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -s -w "\n%{http_code}" -X POST "${LITELLM_BASE_URL%/v1}/v1/messages" -H "x-api-key: ${LITELLM_API_KEY}" -H "Content-Type: application/json" -H "anthropic-version: 2023-06-01" -d '{"model":"'"${LITELLM_MODEL:-gpt-oss-120b}"'","max_tokens":10,"messages":[{"role":"user","content":"Say ok"}]}' 2>&1 | grep -v "Using sandbox")
HTTP_CODE=$(echo "$RESULT" | tail -1)
if [ "$HTTP_CODE" = "200" ]; then
    info "LiteLLM Anthropic API: OK (HTTP 200) - model: ${LITELLM_MODEL:-gpt-oss-120b}"
else
    warn "LiteLLM Anthropic API: HTTP $HTTP_CODE"
fi

step "Test RHOAI MLflow from sandbox"
if [ -n "$OCP_TOKEN" ]; then
    MLF_CODE=$(openshell sandbox exec --name "$SANDBOX_NAME" -- curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${OCP_TOKEN}" -H "X-Mlflow-Workspace: ${MLFLOW_WORKSPACE:-openshell}" "${MLFLOW_SANDBOX_URI}/api/2.0/mlflow/experiments/search?max_results=1" 2>&1 | grep -v "Using sandbox")
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
echo "   claude --model ${LITELLM_MODEL:-gpt-oss-120b}"
echo ""
echo " Model: ${LITELLM_MODEL:-gpt-oss-120b}"
echo " MLflow: ${MLFLOW_SANDBOX_URI}"
echo " MLflow traces: automatic (stop-hook fires after each session)"
echo ""
