# Agent Harness in a Box

Structured demos for running OpenShell and AI coding agents on OpenShift.

## Repository Layout

| Path | Purpose |
|------|---------|
| `common/` | Shared bash functions and pre-flight checks |
| `demos/01-basic-openshell/` | Basic OpenShell installation on OpenShift (no auth) |
| `demos/02-opencode-keycloak/` | OpenCode + Keycloak OIDC auth + optional MLflow |
| `demos/03-claude-code/` | Claude Code + LiteLLM + MLflow (separate from OpenCode) |

## Key Concepts

- **OpenShell Gateway** - Helm-deployed StatefulSet managing sandbox pod lifecycle
- **Agent Sandbox CRD** (`agents.x-k8s.io/v1beta1`) - K8s custom resource for sandbox pods
- **Privileged SCC** - Required for sandbox supervisor (Landlock, seccomp, network namespace)
- **JWT signing secret** - Must be pre-created because Helm chart's PKI init Job is not SCC-compatible on OpenShift
- **Global policy** - Enforced by CONNECT proxy inside every sandbox pod

## OpenShift-Specific Helm Overrides

Every demo uses these overrides because OpenShift SCCs reject the chart defaults:
- `pkiInitJob.enabled=false` - PKI init Job not SCC-compatible
- `server.disableTls=true` - Evaluation mode (TLS needs cert-manager)
- `podSecurityContext.fsGroup=null` - Let OpenShift SCC assign
- `securityContext.runAsUser=null` - Let OpenShift SCC assign

## Reference Projects

- `../ooo/` - OpenCode on OpenShift (install patterns, DevPortal)
- `../openshell-demo/` - OpenShell + GitHub auth + Codex (flow reference)
- `../agentic-starter-kits/` - UBI10 sandbox images, OpenCode deployment
- `../OpenShell/` - NVIDIA upstream (Helm chart, Keycloak realm, OIDC config)
