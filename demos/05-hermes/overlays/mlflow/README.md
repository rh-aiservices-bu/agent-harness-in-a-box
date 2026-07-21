# MLflow Tracing Overlay for Hermes

Enables MLflow tracing for Hermes agent sessions.

See `demos/02-opencode-keycloak/overlays/mlflow/README.md` for detailed RHOAI MLflow setup instructions.

## Quick Setup

MLflow tracing is configured automatically by `setup-sandbox.sh` when an OCP token is available.
The experiment name defaults to `hermes-sandbox`.

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `MLFLOW_TRACKING_URI` | MLflow server URL (set to RHOAI external route) |
| `MLFLOW_TRACKING_TOKEN` | OCP Bearer token for RHOAI auth |
| `MLFLOW_TRACKING_INSECURE_TLS` | Skip TLS verification for self-signed certs |
| `MLFLOW_EXPERIMENT_NAME` | Experiment name (`hermes-sandbox`) |
| `MLFLOW_WORKSPACE` | RHOAI workspace name |
