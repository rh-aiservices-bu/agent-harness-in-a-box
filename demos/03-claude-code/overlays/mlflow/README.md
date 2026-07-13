# MLflow Tracing for Claude Code Sandboxes

Same setup as Demo 2's MLflow overlay. See `../../02-opencode-keycloak/overlays/mlflow/README.md` for details.

## Inside the Sandbox

```bash
OCP_TOKEN=$(oc whoami -t)

export MLFLOW_TRACKING_URI="https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow"
export MLFLOW_TRACKING_TOKEN="$OCP_TOKEN"
export MLFLOW_EXPERIMENT_NAME="claude-code-sandbox"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer $OCP_TOKEN,X-Mlflow-Workspace=openshell"
```
