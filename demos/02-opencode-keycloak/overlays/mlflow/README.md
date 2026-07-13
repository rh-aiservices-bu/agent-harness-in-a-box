# MLflow Tracing for OpenCode Sandboxes

Enable MLflow tracing to track AI agent activity inside OpenShell sandboxes using the RHOAI (Red Hat OpenShift AI) MLflow instance.

## Prerequisites

- Demo 2 deployed and working
- Logged into OpenShift (`oc login`) - required for bearer token authentication
- RHOAI MLflow available at `https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow`

## Authentication

RHOAI MLflow requires two authentication headers on every request:

| Header | Value | Purpose |
|--------|-------|---------|
| `Authorization` | `Bearer <OCP_TOKEN>` | OpenShift bearer token from `oc whoami -t` |
| `X-Mlflow-Workspace` | `openshell` | Multi-tenant workspace identifier |

The `setup-sandbox.sh` script handles this automatically by injecting `MLFLOW_TRACKING_TOKEN` and `OTEL_EXPORTER_OTLP_HEADERS` into the sandbox environment.

## Configure Sandboxes

### Option 1: Use setup-sandbox.sh (recommended)

The setup script automatically configures RHOAI MLflow tracing:

```bash
bash setup-sandbox.sh
```

It sets these environment variables inside the sandbox:

```bash
export MLFLOW_TRACKING_URI="https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow"
export MLFLOW_TRACKING_TOKEN="<OCP_TOKEN>"
export MLFLOW_EXPERIMENT_NAME="opencode-sandbox"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <OCP_TOKEN>,X-Mlflow-Workspace=openshell"
```

### Option 2: Set environment variables manually

After connecting to a sandbox, export the MLflow variables:

```bash
OCP_TOKEN=$(oc whoami -t)

export MLFLOW_TRACKING_URI="https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow"
export MLFLOW_TRACKING_TOKEN="$OCP_TOKEN"
export MLFLOW_EXPERIMENT_NAME="opencode-sandbox"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer $OCP_TOKEN,X-Mlflow-Workspace=openshell"
```

## Network Policy

The global policy (`config/policy.yaml`) already includes an entry for the RHOAI MLflow in-cluster service. Apply it with:

```bash
openshell policy set --global --policy ../../config/policy.yaml --yes
```

## Test from Inside a Sandbox

```bash
OCP_TOKEN=$(oc whoami -t)
MLFLOW_URI="https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow"

# Search experiments
curl -s -H "Authorization: Bearer $OCP_TOKEN" \
  -H "X-Mlflow-Workspace: openshell" \
  "$MLFLOW_URI/api/2.0/mlflow/experiments/search?max_results=1"

# Create an experiment
curl -s -X POST "$MLFLOW_URI/api/2.0/mlflow/experiments/create" \
  -H "Authorization: Bearer $OCP_TOKEN" \
  -H "X-Mlflow-Workspace: openshell" \
  -H "Content-Type: application/json" \
  -d '{"name":"sandbox-test"}'
```

## Verifying Traces

Access the RHOAI MLflow dashboard:

```
https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow
```

Log in with your OpenShift credentials and navigate to the `openshell` workspace to view experiments and runs.
