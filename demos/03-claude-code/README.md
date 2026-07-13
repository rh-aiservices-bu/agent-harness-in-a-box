# Demo 3: Claude Code + LiteLLM + MLflow

Run Claude Code inside OpenShell sandboxes with LiteLLM inference and MLflow tracing. This demo assumes Demo 2 (Keycloak OIDC) is already deployed - it reuses the same OpenShell gateway and authentication.

## What You Will Learn

- How to install Claude Code inside an OpenShell sandbox
- How to configure Claude Code with a LiteLLM endpoint (Anthropic Messages API format)
- How to apply network policies for external API access
- How to trace agent activity with MLflow

## Architecture

```
+------------------+          +----------------------------+
|                  |  gRPC    |                            |
| openshell CLI    +--------->+ OpenShell Gateway          |
|                  |          | (from Demo 2)              |
+------------------+          +-------------+--------------+
                                            |
                              creates       |
                                            v
                              +-------------+--------------+
                              |  Sandbox Pod               |
                              |  - Claude Code CLI         |
                              |  - ANTHROPIC_BASE_URL ->   |
                              |    LiteLLM endpoint        |
                              +----+-----------------+-----+
                                   |                 |
                                   v                 v
                              +----+----+     +------+------+
                              | LiteLLM |     | RHOAI       |
                              | (MaaS)  |     | MLflow      |
                              +---------+     +-------------+
```

## Prerequisites

- Demo 2 deployed and working (OpenShell + Keycloak)
- `openshell` CLI configured and connected to the gateway
- LiteLLM API endpoint and key (stored in `.env` at repo root)

## Quick Start

```bash
# Ensure .env exists with your credentials
cp ../../.env.example ../../.env
# Edit .env with your LiteLLM endpoint and API key

# Run the setup
bash setup-sandbox.sh
```

## Step-by-Step Guide

### Step 1: Apply the network policy

The policy must allow access to your LiteLLM endpoint and MLflow:

```bash
openshell policy set --global --policy config/policy.yaml --yes
```

### Step 2: Create a sandbox

```bash
openshell sandbox create --name claude-demo
```

Wait for it to reach `Ready`:

```bash
openshell sandbox list
```

### Step 3: Install Claude Code

Use a pre-baked sandbox image (recommended):

```bash
openshell sandbox create --name claude-demo \
    --from quay.io/rcarrata/agentic-harness-openshell:claude-code-v1
```

Or install manually inside a default sandbox:

```bash
openshell sandbox connect claude-demo

# Inside the sandbox - install via native installer
curl -fsSL https://claude.ai/install.sh | bash
export PATH="/sandbox/.local/bin:$PATH"
claude --version
```

**Build your own image (optional):**

```bash
cd sandbox-image
podman build --platform linux/amd64 \
    --build-arg CLAUDE_CODE_VERSION=2.1.206 \
    -t quay.io/<your-org>/agentic-harness-openshell:claude-code-v1 \
    -f Containerfile.openshell .
podman push quay.io/<your-org>/agentic-harness-openshell:claude-code-v1
```

### Step 4: Configure LiteLLM as the API backend

Claude Code uses the Anthropic Messages API format (`/v1/messages`). LiteLLM supports this format natively.

If you used `setup-sandbox.sh`, credentials are auto-loaded from `.profile`. For manual setup:

```bash
export ANTHROPIC_API_KEY="your-litellm-api-key"
export ANTHROPIC_BASE_URL="https://your-litellm-endpoint.example.com"
```

Test that the API is reachable:

```bash
curl -s -X POST "${ANTHROPIC_BASE_URL}/v1/messages" \
  -H "x-api-key: ${ANTHROPIC_API_KEY}" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"llama-scout-17b","max_tokens":10,"messages":[{"role":"user","content":"Say hi"}]}'
```

### Step 5: Run Claude Code

Credentials are auto-loaded if you used `setup-sandbox.sh`:

```bash
claude --model llama-scout-17b
```

For non-interactive use (CI/automation):

```bash
claude -p "List the files in /workspace" --model llama-scout-17b
```

### Step 6: Configure RHOAI MLflow tracing (optional)

Agent activity can be tracked via the RHOAI (Red Hat OpenShift AI) MLflow instance. This requires an active OpenShift login for bearer token authentication.

Inside the sandbox:

```bash
OCP_TOKEN=$(oc whoami -t)

export MLFLOW_TRACKING_URI="https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow"
export MLFLOW_TRACKING_TOKEN="$OCP_TOKEN"
export MLFLOW_EXPERIMENT_NAME="claude-code-sandbox"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer $OCP_TOKEN,X-Mlflow-Workspace=openshell"
```

The `setup-sandbox.sh` script configures this automatically when an OCP token is available.

Access the RHOAI MLflow dashboard at `https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow` and navigate to the `openshell` workspace.

## Sandbox Security: Permissive Policy

This demo uses a **permissive** policy - the widest access tier for trusted development. Even at this level, OpenShell still enforces an allowlist. Unrecognized hosts are blocked.

### Full Development Access

The permissive tier allows direct AI APIs, GitHub with full write access, and all package registries:

```bash
# From inside the sandbox:
curl https://api.github.com/repos/NVIDIA/OpenShell     # -> HTTP 200 (GET)
curl -X POST https://api.github.com/repos/.../issues   # -> HTTP 200 (POST allowed!)
curl https://api.anthropic.com/v1/models                # -> HTTP 200 (direct AI API)
curl https://example.com                                # -> HTTP 403 (still blocked!)
```

### Hot-Reload: Switch Policies Without Restart

Network policies are dynamic - they hot-reload via the CONNECT proxy without restarting the sandbox. The test script demonstrates switching from permissive to strict and back:

```bash
# Apply strict - everything locks down instantly
openshell policy set --global --policy ../01-basic-openshell/config/policy-strict.yaml --yes
curl https://api.github.com     # -> HTTP 403 (was 200 seconds ago!)

# Restore permissive - access returns
openshell policy set --global --policy /tmp/policy-permissive-rendered.yaml --yes
curl https://api.github.com     # -> HTTP 200 (back to normal)
```

### Security Tiers Comparison

| Feature | Strict (Demo 01) | Standard (Demo 02) | Permissive (Demo 03) |
|---------|-------------------|---------------------|----------------------|
| Inference (LiteLLM) | Agent binaries only | All binaries | All binaries |
| Package registries | Blocked | Allowed | Allowed |
| GitHub | Blocked | Read-only | Full access |
| Direct AI APIs | Blocked | Blocked | Allowed |
| Filesystem (Landlock) | Identical across all tiers | | |
| Process isolation | Identical across all tiers | | |

### Run the Full Security Test

```bash
bash setup-sandbox.sh              # create sandbox with permissive policy
bash test-sandbox-security.sh      # run all tests including hot-reload demo
```

This runs network access, hot-reload switching, Landlock, and process isolation tests.

## Environment Variables Reference

| Variable | Purpose | Example |
|----------|---------|---------|
| `ANTHROPIC_API_KEY` | API key for the inference endpoint | `sk-...` |
| `ANTHROPIC_BASE_URL` | Base URL for the Anthropic Messages API | `https://your-endpoint.example.com` |
| `MLFLOW_TRACKING_URI` | RHOAI MLflow URL | `https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow` |
| `MLFLOW_TRACKING_TOKEN` | OCP bearer token for MLflow auth | `<from oc whoami -t>` |
| `MLFLOW_EXPERIMENT_NAME` | MLflow experiment name | `claude-code-sandbox` |

## Teardown

Remove the sandbox:

```bash
openshell sandbox delete claude-demo
```

For full teardown including the gateway and Keycloak, use Demo 2's teardown script.

## Troubleshooting

**Claude Code hangs on first run:**

Claude Code may prompt for terms acceptance on first launch. Run it interactively once (`openshell sandbox connect`, then `claude`) to complete the onboarding flow.

**"ECONNRESET" when installing via npm:**

The CONNECT proxy may reset connections for large npm packages. Use the manual binary download method shown in Step 3.

**API returns 403 from sandbox:**

The network policy doesn't allow the endpoint. Check that `config/policy-permissive.yaml.template` includes your LiteLLM hostname and re-apply with `openshell policy set --global`.

**"Incorrect API key" errors:**

Verify your API key works outside the sandbox first:
```bash
curl -s -X POST "https://your-endpoint.example.com/v1/messages" \
  -H "x-api-key: YOUR_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama-scout-17b","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}'
```
