# OpenShell Gateway with Passthrough TLS on OpenShift

Expose the OpenShell gRPC gateway through an OpenShift Route without port-forward, using passthrough TLS to preserve gRPC trailers.

## Overview

The OpenShell gateway uses gRPC (HTTP/2) for all CLI-to-gateway communication. OpenShift's default HAProxy router terminates TLS and re-encodes traffic, which strips gRPC trailing metadata (`grpc-status`, `grpc-message`). Without these trailers, every gRPC call fails with:

```
missing grpc-status trailer, stream was terminated without a final status
```

A **passthrough TLS** route solves this by forwarding raw TCP to the gateway pod. HAProxy never inspects the HTTP/2 frames, so gRPC trailers arrive intact. The trade-off is that the gateway must terminate TLS itself.

## Why Other Route Types Fail

| Method | Works? | Reason |
|---|---|---|
| Route (plain h2c) | No | HAProxy strips gRPC trailers during HTTP/2 re-encoding |
| Route (edge TLS) | No | Same trailer stripping - TLS terminates at the router, h2c backend |
| Route (re-encrypt TLS) | No | HAProxy still parses HTTP/2 frames between its two TLS sessions |
| Route (passthrough TLS) | Yes | HAProxy forwards raw TCP - never touches HTTP/2 frames or trailers |
| AWS NLB (LoadBalancer) | Yes | L4 TCP load balancer bypasses the router entirely |
| Port-forward | Yes | Direct tunnel - not production-viable |

Passthrough TLS is the only OpenShift Route type that works with gRPC because it is the only one where HAProxy does not decode the application-layer protocol.

## Prerequisites

- OpenShift 4.x cluster with `oc` CLI authenticated as cluster-admin
- OpenShell gateway deployed via Helm (chart v0.0.86+)
- `openshell` CLI v0.0.86+
- `openssl` for certificate generation

## Step-by-Step

### Step 1: Generate a Self-Signed TLS Certificate

The certificate needs SANs (Subject Alternative Names) for both the external route hostname and internal Kubernetes service names.

```bash
# Set your cluster's apps domain
APPS_DOMAIN="apps.ocp.example.com"
NAMESPACE="openshell"
ROUTE_HOST="openshell-gw-${NAMESPACE}.${APPS_DOMAIN}"

# Generate RSA key + self-signed cert with SANs
openssl req -x509 -nodes -newkey rsa:4096 \
  -keyout /tmp/gw-tls.key \
  -out /tmp/gw-tls.crt \
  -days 365 \
  -subj "/CN=${ROUTE_HOST}" \
  -addext "subjectAltName=DNS:${ROUTE_HOST},DNS:openshell.${NAMESPACE}.svc.cluster.local,DNS:openshell,DNS:openshell.${NAMESPACE}.svc"
```

The SANs ensure:
- External clients trust the cert via the route hostname
- Sandbox supervisors trust the cert via the internal service DNS

### Step 2: Create the TLS Secret

The secret needs three keys: `tls.crt`, `tls.key`, and `ca.crt`. For a self-signed cert, `ca.crt` is the same as `tls.crt`. The `ca.crt` is mounted into sandbox pods so the supervisor can verify the gateway's certificate.

```bash
oc create secret generic openshell-tls \
  --from-file=tls.crt=/tmp/gw-tls.crt \
  --from-file=tls.key=/tmp/gw-tls.key \
  --from-file=ca.crt=/tmp/gw-tls.crt \
  -n ${NAMESPACE}
```

### Step 3: Update the Gateway ConfigMap

Replace the gateway configuration to enable TLS and point to the certificate paths. The `client_tls_secret_name` tells the gateway which secret to mount into sandbox pods for supervisor-to-gateway TLS verification.

```bash
cat > /tmp/gateway.toml << EOF
[openshell]
version = 1

[openshell.gateway]
bind_address          = "0.0.0.0:8080"
health_bind_address   = "0.0.0.0:8081"
metrics_bind_address  = "0.0.0.0:9090"
log_level             = "info"
sandbox_namespace     = "${NAMESPACE}"
default_image         = "ghcr.io/nvidia/openshell-community/sandboxes/base:latest"
disable_tls            = false
enable_loopback_service_http = true
client_tls_secret_name = "openshell-tls"

[openshell.gateway.tls]
cert_path = "/etc/openshell-tls/tls.crt"
key_path  = "/etc/openshell-tls/tls.key"

[openshell.gateway.auth]
allow_unauthenticated_users = true

[openshell.gateway.gateway_jwt]
signing_key_path = "/etc/openshell-jwt/signing.pem"
public_key_path  = "/etc/openshell-jwt/public.pem"
kid_path         = "/etc/openshell-jwt/kid"
gateway_id       = "openshell"
ttl_secs         = 3600

[openshell.drivers.kubernetes]
grpc_endpoint                = "https://openshell.${NAMESPACE}.svc.cluster.local:8080"
service_account_name         = "openshell-sandbox"
supervisor_sideload_method   = "init-container"
topology                     = "combined"
sa_token_ttl_secs            = 3600
app_armor_profile            = "Unconfined"
EOF

oc create configmap openshell-config \
  --from-file=gateway.toml=/tmp/gateway.toml \
  -n ${NAMESPACE} --dry-run=client -o yaml | oc apply -f -
```

Key settings:
- `disable_tls = false` - double negative: "do not disable TLS", meaning TLS is **enabled** and the gateway serves encrypted HTTPS on port 8080
- `enable_loopback_service_http = true` - health probes (on port 8081) still work over HTTP
- `client_tls_secret_name = "openshell-tls"` - mounts the CA cert into sandbox pods at `/etc/openshell-tls/client/ca.crt`
- `grpc_endpoint = "https://..."` - sandbox supervisors connect to the gateway via HTTPS internally

### Step 4: Patch the StatefulSet to Mount the TLS Secret

The gateway pod needs the TLS cert and key mounted as a volume.

```bash
oc patch statefulset openshell -n ${NAMESPACE} --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "openshell-tls",
      "secret": {
        "secretName": "openshell-tls",
        "defaultMode": 256
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "openshell-tls",
      "mountPath": "/etc/openshell-tls",
      "readOnly": true
    }
  }
]'
```

### Step 5: Restart the Gateway

Delete the pod to force recreation with the new config and volume mounts.

```bash
oc delete pod openshell-0 -n ${NAMESPACE}

# Wait for the gateway to come back
oc rollout status statefulset/openshell -n ${NAMESPACE} --timeout=120s
```

Verify TLS is working in the gateway logs:

```bash
oc logs openshell-0 -n ${NAMESPACE} --tail=10 | grep -i tls
# Expected: "TLS enabled - listening on encrypted HTTPS"
# Expected: "TLS certificate file watcher started"
```

### Step 6: Delete Existing Routes (if any)

Remove any old edge/h2c routes that won't work with the TLS-enabled gateway.

```bash
oc delete route openshell-gw -n ${NAMESPACE} 2>/dev/null || true
```

### Step 7: Create the Passthrough TLS Route

```bash
ROUTE_HOST="openshell-gw-${NAMESPACE}.${APPS_DOMAIN}"

oc create route passthrough openshell-gw \
  --service=openshell \
  --port=8080 \
  --hostname="${ROUTE_HOST}" \
  -n ${NAMESPACE}
```

Verify the route:

```bash
oc get route openshell-gw -n ${NAMESPACE}
# TERMINATION column should show: passthrough
```

### Step 8: Verify TLS Connectivity

Test that the route correctly passes through TLS to the gateway:

```bash
curl -vsk https://${ROUTE_HOST}/healthz 2>&1 | grep -E "SSL|TLS|HTTP"
# Expected: TLSv1.3 handshake, ALPN h2 accepted
```

### Step 9: Register the Gateway with openshell CLI

Register the gateway endpoint. Use `--local` to skip OIDC auth and `--gateway-insecure` to accept the self-signed cert.

```bash
ROUTE_HOST="openshell-gw-${NAMESPACE}.${APPS_DOMAIN}"

openshell gateway add \
  --name my-cluster \
  --local \
  --gateway-insecure \
  https://${ROUTE_HOST}
```

For all subsequent `openshell` commands, either pass `--gateway-insecure` or export the env var:

```bash
export OPENSHELL_GATEWAY_INSECURE=true
```

### Step 10: Verify Sandbox Operations

```bash
export OPENSHELL_GATEWAY_INSECURE=true

# List sandboxes (gRPC through passthrough route)
openshell sandbox list

# Create a test sandbox
openshell sandbox create --name test-sandbox

# Execute a command
openshell sandbox exec --name test-sandbox -- whoami

# Clean up
openshell sandbox delete test-sandbox
```

## Recreating Sandboxes After Enabling TLS

If sandboxes existed before TLS was enabled, they must be deleted and recreated. The sandbox supervisor establishes its gRPC connection at pod startup - existing supervisors will fail because they were configured for plaintext HTTP. New sandboxes get the correct HTTPS endpoint and the CA cert automatically.

```bash
export OPENSHELL_GATEWAY_INSECURE=true

# Delete old sandboxes
openshell sandbox delete my-sandbox

# Recreate - supervisor will connect via HTTPS using the mounted CA cert
openshell sandbox create --name my-sandbox
```

## Quick Start (All Commands)

Run from any terminal with `oc` and `openshell` installed:

```bash
# Variables
APPS_DOMAIN="apps.ocp.example.com"
NAMESPACE="openshell"
ROUTE_HOST="openshell-gw-${NAMESPACE}.${APPS_DOMAIN}"
GATEWAY_NAME="my-cluster"

# 1. Generate TLS cert
openssl req -x509 -nodes -newkey rsa:4096 \
  -keyout /tmp/gw-tls.key -out /tmp/gw-tls.crt -days 365 \
  -subj "/CN=${ROUTE_HOST}" \
  -addext "subjectAltName=DNS:${ROUTE_HOST},DNS:openshell.${NAMESPACE}.svc.cluster.local,DNS:openshell,DNS:openshell.${NAMESPACE}.svc"

# 2. Create secret (with ca.crt = tls.crt for self-signed)
oc create secret generic openshell-tls \
  --from-file=tls.crt=/tmp/gw-tls.crt \
  --from-file=tls.key=/tmp/gw-tls.key \
  --from-file=ca.crt=/tmp/gw-tls.crt \
  -n ${NAMESPACE}

# 3. Update ConfigMap (see Step 3 above for full gateway.toml)
oc create configmap openshell-config \
  --from-file=gateway.toml=/tmp/gateway.toml \
  -n ${NAMESPACE} --dry-run=client -o yaml | oc apply -f -

# 4. Patch StatefulSet for TLS volume
oc patch statefulset openshell -n ${NAMESPACE} --type='json' -p='[
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"openshell-tls","secret":{"secretName":"openshell-tls","defaultMode":256}}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"openshell-tls","mountPath":"/etc/openshell-tls","readOnly":true}}
]'

# 5. Restart gateway
oc delete pod openshell-0 -n ${NAMESPACE}
oc rollout status statefulset/openshell -n ${NAMESPACE} --timeout=120s

# 6. Delete old route
oc delete route openshell-gw -n ${NAMESPACE} 2>/dev/null || true

# 7. Create passthrough route
oc create route passthrough openshell-gw \
  --service=openshell --port=8080 \
  --hostname="${ROUTE_HOST}" -n ${NAMESPACE}

# 8. Register gateway
openshell gateway add --name ${GATEWAY_NAME} --local --gateway-insecure https://${ROUTE_HOST}
export OPENSHELL_GATEWAY_INSECURE=true

# 9. Verify
openshell sandbox list
```

## Summary

Passthrough TLS is the production-viable way to expose an OpenShell gRPC gateway through OpenShift Routes. It avoids the gRPC trailer stripping problem inherent in edge, re-encrypt, and h2c route types by keeping HAProxy out of the HTTP/2 frame path entirely.

The key pieces:
1. **Self-signed TLS cert** with SANs for both external route and internal service DNS
2. **TLS secret** with `ca.crt` so sandbox supervisors can verify the gateway
3. **Gateway config** with `disable_tls=false`, `client_tls_secret_name`, and HTTPS `grpc_endpoint`
4. **StatefulSet patch** to mount the TLS secret into the gateway pod
5. **Passthrough route** that forwards raw TCP/TLS to the gateway
6. **CLI env var** `OPENSHELL_GATEWAY_INSECURE=true` for self-signed cert acceptance

The alternative is an AWS NLB (`service.beta.kubernetes.io/aws-load-balancer-type: nlb`), which bypasses the OpenShift router at L4 but is cloud-specific, requires DNS propagation time, and is not available on bare-metal or non-AWS clusters.
