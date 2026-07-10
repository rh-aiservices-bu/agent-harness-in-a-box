# Agent Harness in a Box

Structured demos for running OpenShell and AI coding agents on OpenShift. Each demo is self-contained with step-by-step instructions, automated install scripts, and verification.

## What is OpenShell?

OpenShell is NVIDIA's agent-first platform providing safe, sandboxed runtimes for autonomous AI agents. It enforces security boundaries through Landlock filesystem isolation, seccomp syscall filtering, and network policy enforcement via an HTTP CONNECT proxy.

## Demos

| Demo | Description | Auth | AI Agent | Inference |
|------|-------------|------|----------|-----------|
| [01-basic-openshell](demos/01-basic-openshell/) | Basic OpenShell installation | None | Default | N/A |
| [02-opencode-keycloak](demos/02-opencode-keycloak/) | OpenCode/Claude Code + Keycloak OIDC + MLflow | Keycloak | OpenCode, Claude Code | LiteLLM |

## Prerequisites

- OpenShift 4.19+ cluster with cluster-admin access
- `oc` CLI configured and logged in
- Helm 3.x
- `openshell` CLI ([install guide](https://docs.nvidia.com/openshell/latest/install))

## Quick Start

```bash
# Check prerequisites
bash common/prerequisites.sh

# Run Demo 1
cd demos/01-basic-openshell
bash install.sh

# Verify
bash verify.sh

# Teardown when done
bash teardown.sh
```

## Test Cluster

The demos have been tested on:
- OpenShift 4.20 on AWS (gp3-csi storage)
- OpenShift AI 3.4.2 with MLflow

## References

- [OpenShell Documentation](https://docs.nvidia.com/openshell/latest/)
- [OpenShell on OpenShift](https://docs.nvidia.com/openshell/latest/kubernetes/openshift)
- [Agent Sandbox SIG](https://github.com/kubernetes-sigs/agent-sandbox)
- [Red Hat build of Agent Sandbox](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_agent_sandbox/)
