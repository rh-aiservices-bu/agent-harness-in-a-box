# Self-Hosted Inference with vLLM

Deploy vLLM as a self-hosted model server and configure OpenShell to route inference through it.

## Prerequisites

- GPU nodes available on your cluster (2x NVIDIA GPUs recommended)
- Hugging Face token for gated models

## Deploy vLLM

1. Create the vLLM namespace and Hugging Face token secret:

```bash
oc create ns vllm
oc -n vllm create secret generic vllm-hf-token --from-literal=token=<your-hf-token>
```

2. Apply the vLLM deployment:

```bash
oc apply -f deployment.yaml
```

3. Wait for the model to download and the server to start:

```bash
oc -n vllm rollout status deployment/vllm --timeout=600s
```

## Configure OpenShell inference

```bash
# Create a provider
openshell provider create openai \
    --name vllm \
    --base-url http://vllm-svc.vllm.svc.cluster.local:8000/v1 \
    --api-key dummy

# Set as the default inference route
openshell inference set --provider vllm --model <model-name>
```

Inside sandboxes, agents can now reach the model at `https://inference.local/v1`.

## Reference

This overlay is adapted from the openshell-demo vLLM deployment.
See: `openshell-demo/manifests/vllm/deployment.yaml`
