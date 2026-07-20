#!/bin/sh
set -e

GW_ENDPOINT="${OPENSHELL_GATEWAY_ENDPOINT:-http://openshell.${NAMESPACE:-openshell-ctf}.svc.cluster.local:8080}"

openshell gateway add "$GW_ENDPOINT" --local --name cluster 2>/dev/null || true
openshell gateway select cluster 2>/dev/null || true

export OPENSHELL_GATEWAY=cluster

exec uvicorn app:app --host 0.0.0.0 --port 8000
