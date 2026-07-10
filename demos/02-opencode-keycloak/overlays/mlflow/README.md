# MLflow Tracing for OpenCode Sandboxes

Enable MLflow tracing to track AI agent activity inside OpenShell sandboxes.

## Prerequisites

- Demo 2 deployed and working
- Standalone MLflow deployed in the `openshell` namespace (see below)

## Deploy Standalone MLflow

Apply the MLflow deployment manifest:

```bash
oc apply -f deployment.yaml
```

Wait for it to start:

```bash
oc -n openshell rollout status deployment/mlflow --timeout=120s
```

Verify it's healthy:

```bash
curl -s http://$(oc -n openshell get route mlflow -o jsonpath='{.spec.host}')/health
# Expected: OK
```

**Why standalone MLflow?** OpenShift AI includes MLflow, but it uses multi-tenant workspace authentication that requires a workspace context not available from sandboxes. A standalone MLflow instance in the same namespace avoids this.

## Configure Sandboxes

### Option 1: Set environment variables in the sandbox

After connecting to a sandbox, export the MLflow variables:

```bash
export MLFLOW_TRACKING_URI="http://mlflow.openshell.svc.cluster.local:5000"
export MLFLOW_EXPERIMENT_NAME="opencode-sandbox"

# Install the MLflow Python package (if not in the sandbox image)
pip install mlflow

# Verify connectivity
curl -s $MLFLOW_TRACKING_URI/health
# Expected: OK
```

### Option 2: Inject via sandbox environment

When creating a sandbox with the OpenShell gRPC API, include MLflow env vars in the `SandboxSpec.environment` field. See `env-patch.yaml` for the variable list.

## Network Policy

The global policy must include an entry for MLflow. This is already included in `config/policy.yaml`:

```yaml
mlflow_local:
  name: "MLflow (in-cluster)"
  endpoints:
    - host: "mlflow.openshell.svc.cluster.local"
      ports: [5000]
      protocol: rest
      enforcement: enforce
      access: full
  binaries:
    - { path: "**" }
```

Apply with:

```bash
openshell policy set --global --policy ../../config/policy.yaml --yes
```

## Test from Inside a Sandbox

```bash
# Create an experiment
curl -s -X POST http://mlflow.openshell.svc.cluster.local:5000/api/2.0/mlflow/experiments/create \
  -H "Content-Type: application/json" \
  -d '{"name":"sandbox-test"}'

# Create a run
curl -s -X POST http://mlflow.openshell.svc.cluster.local:5000/api/2.0/mlflow/runs/create \
  -H "Content-Type: application/json" \
  -d '{"experiment_id":"1","run_name":"test-run"}'

# Log a metric
curl -s -X POST http://mlflow.openshell.svc.cluster.local:5000/api/2.0/mlflow/runs/log-metric \
  -H "Content-Type: application/json" \
  -d '{"run_id":"<run-id>","key":"tokens_used","value":42,"timestamp":0,"step":0}'
```

## Verifying Traces

Access the MLflow UI:

```bash
MLFLOW_ROUTE=$(oc -n openshell get route mlflow -o jsonpath='{.spec.host}')
echo "MLflow UI: http://$MLFLOW_ROUTE"
```

Navigate to the experiment and check for runs and metrics from sandbox sessions.
