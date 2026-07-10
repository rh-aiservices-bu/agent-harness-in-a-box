# Demo 2: OpenCode + Keycloak OIDC + MLflow

Deploy OpenShell on OpenShift with Keycloak authentication, OpenCode as the AI coding agent, and optional MLflow tracing. This demo builds on Demo 1 by adding OIDC authentication so users must log in before accessing sandboxes.

## What You Will Learn

- How to deploy Keycloak on OpenShift and configure OIDC for OpenShell
- How OIDC tokens flow between the CLI, Keycloak, and the OpenShell gateway
- How to build a custom sandbox image with OpenCode pre-installed
- How to use OpenCode inside a sandboxed environment
- How to add MLflow tracing to track agent activity

## Architecture

```
+--------------+    OIDC     +------------------+
|              +------------>+                  |
| openshell    |    login    |  Keycloak        |
| CLI          +<------------+  (OIDC Provider) |
|              |    JWT      |                  |
+------+-------+             +------------------+
       |
       | gRPC + Bearer token
       v
+------+----------+         +-------------------+
|                  | creates |                   |
| OpenShell        +-------->+ Sandbox Pods      |
| Gateway          |         | (OpenCode agent)  |
| (validates JWT)  |         |                   |
+---------+--------+         +---------+---------+
          |                            |
          |  inference.local           | (optional)
          +----------------------------+-----------> MLflow
```

**How OIDC works with OpenShell:**

1. The CLI opens a browser to the Keycloak login page
2. User authenticates with username/password (local Keycloak users)
3. Keycloak issues a signed JWT with `realm_access.roles` containing `openshell-admin` or `openshell-user`
4. The CLI presents the JWT as a Bearer token on every gRPC call
5. The gateway validates the JWT against Keycloak's JWKS endpoint (in-cluster URL)
6. Role-based access: admins can manage providers and policies, users can create sandboxes

**Why Keycloak instead of Dex:**

The original openshell-demo uses Dex as an OIDC bridge for GitHub OAuth. Keycloak is a full OIDC provider that supports local users directly, with no external IdP dependency. OpenShell has native Keycloak support with a pre-built realm configuration.

## Prerequisites

- OpenShift 4.19+ cluster with cluster-admin access
- `oc` CLI configured and logged in
- Helm 3.x
- `openshell` CLI installed
- `podman` or `docker` for building the sandbox image (optional if using pre-built images)

## Quick Start (Automated)

```bash
bash install.sh
```

This runs all steps below automatically. Continue reading for the manual walkthrough.

## Step-by-Step Guide

### Step 1: Prerequisites check

```bash
bash ../../common/prerequisites.sh
```

### Step 2: Deploy Keycloak

Create the namespace and apply all Keycloak manifests:

```bash
oc apply -f manifests/keycloak/namespace.yaml
oc apply -f manifests/keycloak/realm-configmap.yaml
oc apply -f manifests/keycloak/deployment.yaml
oc apply -f manifests/keycloak/service.yaml
```

Wait for Keycloak to be ready (it takes about 30-60 seconds to start and import the realm):

```bash
oc -n openshell-keycloak rollout status deployment/keycloak --timeout=120s
```

**What happens during startup:**

- Keycloak starts in `start-dev` mode (H2 in-memory database, no persistence needed for demos)
- The `--import-realm` flag imports the realm JSON from the mounted ConfigMap
- `KC_HOSTNAME` is set to `keycloak.openshell-keycloak.svc.cluster.local` so that tokens always carry this in-cluster hostname as the `iss` (issuer) claim, regardless of how they were obtained

**The pre-configured realm includes:**

| Resource | Details |
|----------|---------|
| Realm | `openshell` |
| Roles | `openshell-admin` (full access), `openshell-user` (standard access) |
| Client `openshell-cli` | Public client with PKCE (for interactive CLI login) |
| Client `openshell-ci` | Confidential client (for CI/automation) |
| User `admin@test` | Password: `admin` - has both admin and user roles |
| User `user@test` | Password: `user` - has user role only |

### Step 3: Expose Keycloak

Create a Route for the Keycloak admin console and OIDC endpoints:

```bash
oc apply -f manifests/keycloak/route.yaml
```

Verify the OIDC discovery endpoint responds:

```bash
KC_ROUTE=$(oc -n openshell-keycloak get route keycloak -o jsonpath='{.spec.host}')
curl -sk "https://$KC_ROUTE/realms/openshell/.well-known/openid-configuration" | python3 -m json.tool | head -10
```

You should see a JSON response with `issuer`, `authorization_endpoint`, `token_endpoint`, etc.

**Access the admin console (optional):**

Open `https://<KC_ROUTE>` in your browser and log in with `admin`/`admin` to explore the realm, users, and clients.

### Step 4: Customize Keycloak users (optional)

To add custom users, either:

**Option A: Via the admin console**
1. Log in at `https://<KC_ROUTE>`
2. Select the `openshell` realm (dropdown in the top-left)
3. Go to Users > Add user
4. Set username and email, then go to Credentials tab to set a password
5. Go to Role Mapping tab and assign `openshell-user` (or `openshell-admin`)

**Option B: Via the realm JSON**
Edit `manifests/keycloak/realm-configmap.yaml` and add entries to the `users` array, then reapply:
```bash
oc apply -f manifests/keycloak/realm-configmap.yaml
oc -n openshell-keycloak rollout restart deployment/keycloak
```

### Step 5: Install Agent Sandbox CRDs

If you already completed Demo 1, skip this step.

```bash
oc apply -f \
    https://github.com/kubernetes-sigs/agent-sandbox/releases/latest/download/manifest.yaml
oc -n agent-sandbox-system wait --for=condition=Ready pod \
    -l control-plane=controller-manager --timeout=120s
```

### Step 6: Configure OpenShift for OpenShell

Create the namespace, SCC binding, and JWT signing secret:

```bash
# Create namespace
oc create ns openshell --dry-run=client -o yaml | oc apply -f -

# Grant privileged SCC to sandbox service account
oc adm policy add-scc-to-user privileged -z openshell-sandbox -n openshell

# Create JWT signing secret (if not already created by Demo 1)
if ! oc -n openshell get secret openshell-jwt-keys &>/dev/null; then
    openssl genpkey -algorithm Ed25519 -out /tmp/jwt-signing.pem
    openssl pkey -in /tmp/jwt-signing.pem -pubout -out /tmp/jwt-public.pem
    KID=$(openssl pkey -in /tmp/jwt-signing.pem -pubout -outform DER \
        | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
    echo "$KID" > /tmp/jwt-kid.txt
    oc -n openshell create secret generic openshell-jwt-keys \
        --from-file=signing.pem=/tmp/jwt-signing.pem \
        --from-file=public.pem=/tmp/jwt-public.pem \
        --from-file=kid=/tmp/jwt-kid.txt
    rm -f /tmp/jwt-signing.pem /tmp/jwt-public.pem /tmp/jwt-kid.txt
fi
```

### Step 7: Install OpenShell with Keycloak OIDC

Install using the Keycloak values overlay, which includes both OpenShift overrides and OIDC configuration:

```bash
helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
    --namespace openshell \
    -f manifests/openshell/values-keycloak.yaml
```

Wait for the gateway:

```bash
oc -n openshell rollout status statefulset/openshell --timeout=300s
```

**What the OIDC configuration does:**

| Setting | Value | Purpose |
|---------|-------|---------|
| `oidc.issuer` | `http://keycloak.openshell-keycloak.svc.cluster.local/realms/openshell` | In-cluster Keycloak URL (tokens carry this as `iss`) |
| `oidc.audience` | `openshell-cli` | Must match the client ID in Keycloak |
| `oidc.rolesClaim` | `realm_access.roles` | Where Keycloak puts roles in the JWT |
| `oidc.adminRole` | `openshell-admin` | Maps to Keycloak realm role |
| `oidc.userRole` | `openshell-user` | Maps to Keycloak realm role |

The gateway fetches Keycloak's JWKS (public keys) from the issuer URL inside the cluster to validate tokens. No external connectivity is needed.

### Step 8: Create the gateway Route and register

```bash
oc -n openshell apply -f manifests/openshell/route.yaml
```

Register the gateway with OIDC:

```bash
GW_URL="http://$(oc -n openshell get route openshell-gw -o jsonpath='{.spec.host}')"

openshell gateway add "$GW_URL" \
    --name openshift \
    --oidc-issuer "http://keycloak.openshell-keycloak.svc.cluster.local/realms/openshell" \
    --oidc-client-id "openshell-cli"
```

**Authenticate with the gateway:**

The CLI needs to reach Keycloak to perform the OIDC login. Since the issuer is an in-cluster URL, set up a port-forward:

```bash
# In a separate terminal
oc -n openshell-keycloak port-forward svc/keycloak 9090:80
```

Then login:

```bash
openshell gateway login openshift
```

This opens your browser to the Keycloak login page. Log in with `admin@test` / `admin` (or `user@test` / `user`).

Verify authentication works:

```bash
openshell status
```

### Step 9: Build the OpenCode sandbox image (optional)

If you want to use a custom sandbox image with OpenCode pre-installed:

```bash
cd sandbox-image

# Build the image
podman build --platform linux/amd64 -t opencode-sandbox:latest -f Containerfile .

# Tag and push to a registry accessible from your cluster
podman tag opencode-sandbox:latest quay.io/<your-org>/opencode-sandbox:latest
podman push quay.io/<your-org>/opencode-sandbox:latest
```

The Containerfile builds on the `openshell-base` image (UBI 10 minimal) and adds Node.js + OpenCode 1.17.1.

If you skip this step, sandboxes will use the default image from the Helm chart.

### Step 10: Create an OpenCode sandbox

Create a sandbox (optionally with the custom image):

```bash
# With default image
openshell sandbox create --name opencode-test

# With custom OpenCode image
openshell sandbox create --name opencode-test \
    --image quay.io/<your-org>/opencode-sandbox:latest
```

Connect to it:

```bash
openshell sandbox connect opencode-test
```

Inside the sandbox, configure OpenCode with your LiteLLM API key and start coding:

```bash
# Set your LiteLLM API key (OpenAI-compatible endpoint)
export OPENAI_API_KEY="your-litellm-key"
export OPENAI_BASE_URL="https://your-litellm-endpoint.example.com/v1"

# Run OpenCode
opencode
```

### Step 11: Configure LiteLLM inference

Register a LiteLLM-compatible API as an OpenShell provider:

```bash
# Register the LiteLLM provider
openshell provider create openai \
    --name litellm \
    --base-url https://your-litellm-endpoint.example.com/v1 \
    --api-key <your-api-key>

# Route inference through the provider
openshell inference set --provider litellm --model gpt-oss-120b --role user
openshell inference set --provider litellm --model llama-scout-17b --role system
```

**Apply the network policy** so sandboxes can reach LiteLLM:

```bash
openshell policy set --global --policy config/policy.yaml --yes
```

**Direct API access from sandbox:**

The simplest approach is to pass API credentials directly into the sandbox via environment variables. This bypasses inference.local and talks directly to LiteLLM:

```bash
# Inside the sandbox
curl -X POST https://your-litellm-endpoint.example.com/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama-scout-17b","messages":[{"role":"user","content":"Hello"}]}'
```

See `overlays/vllm/` for deploying a self-hosted vLLM model server instead.

### Step 12: Deploy MLflow for tracing

Deploy a standalone MLflow server for agent activity tracking:

```bash
oc apply -f overlays/mlflow/deployment.yaml
oc -n openshell rollout status deployment/mlflow --timeout=120s
```

Create an experiment:

```bash
MLFLOW_URL="http://mlflow.openshell.svc.cluster.local:5000"
curl -s -X POST "$MLFLOW_URL/api/2.0/mlflow/experiments/create" \
  -H "Content-Type: application/json" \
  -d '{"name":"opencode-sandbox"}'
```

Inside a sandbox, configure MLflow tracing:

```bash
export MLFLOW_TRACKING_URI="http://mlflow.openshell.svc.cluster.local:5000"
export MLFLOW_EXPERIMENT_NAME="opencode-sandbox"
```

Access the MLflow UI:

```bash
echo "http://$(oc -n openshell get route mlflow -o jsonpath='{.spec.host}')"
```

See `overlays/mlflow/README.md` for detailed setup instructions.

### Step 13: Claude Code in sandbox (optional)

Claude Code can also run inside OpenShell sandboxes:

```bash
# Build the Claude Code sandbox image
cd sandbox-image
podman build --platform linux/amd64 -t claude-code-sandbox:latest -f Containerfile.claude-code .
podman tag claude-code-sandbox:latest quay.io/<your-org>/claude-code-sandbox:latest
podman push quay.io/<your-org>/claude-code-sandbox:latest
cd ..
```

Create a sandbox with Claude Code:

```bash
openshell sandbox create --name claude-sandbox \
    --image quay.io/<your-org>/claude-code-sandbox:latest
openshell sandbox connect claude-sandbox
```

Inside the sandbox:

```bash
export ANTHROPIC_API_KEY="your-anthropic-key"
claude
```

The network policy (`config/policy.yaml`) already includes `api.anthropic.com` access.

## Teardown

Remove everything:

```bash
bash teardown.sh
```

This removes both the OpenShell and Keycloak namespaces.

## Troubleshooting

**"PermissionDenied" when accessing the gateway:**

The OIDC token does not have the required roles. Check that:
1. The user has `openshell-admin` or `openshell-user` role in Keycloak
2. The `rolesClaim` in Helm values matches Keycloak's token structure (`realm_access.roles`)

Decode your token to inspect it:
```bash
# Get the token (stored locally by openshell CLI)
openshell gateway login openshift 2>&1 | grep -i token
```

**"issuer mismatch" or token validation errors:**

The `iss` claim in the JWT must exactly match the `oidc.issuer` in the Helm values. Both must use the in-cluster Keycloak service hostname:
```
http://keycloak.openshell-keycloak.svc.cluster.local/realms/openshell
```

If you see mismatches, check `KC_HOSTNAME` on the Keycloak deployment.

**Self-signed certificate errors:**

If the cluster uses self-signed ingress certificates:

```bash
# Option 1: Use insecure mode
openshell gateway add "$GW_URL" --gateway-insecure ...

# Option 2: Extract and trust the ingress CA
oc -n openshift-ingress get secret router-certs-default \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/ingress-ca.pem
export SSL_CERT_FILE=/tmp/ingress-ca.pem
```

**Keycloak pod not starting:**

Check the logs:
```bash
oc -n openshell-keycloak logs deployment/keycloak
```

Common issues:
- Realm JSON syntax error in the ConfigMap
- Resource limits too low (Keycloak needs at least 512Mi)

**Cannot reach Keycloak for CLI login:**

The OIDC issuer URL points to an in-cluster hostname. You need a port-forward for the CLI to reach it:
```bash
oc -n openshell-keycloak port-forward svc/keycloak 9090:80
```

## References

- [OpenShell Access Control](https://docs.nvidia.com/openshell/latest/kubernetes/access-control)
- [OpenShell on OpenShift](https://docs.nvidia.com/openshell/latest/kubernetes/openshift)
- [Keycloak Documentation](https://www.keycloak.org/documentation)
