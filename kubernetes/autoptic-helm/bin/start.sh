#!/usr/bin/env bash
set -euo pipefail

# Simple start script for the autoptic-helm chart
# Env overrides:
#   RELEASE (default: autoptic)
#   NAMESPACE (default: server)
#   INGRESS_ENABLED (default: false)
#   API_SVC_TYPE (default: ClusterIP)
#   UI_SVC_TYPE (default: ClusterIP)
#   PORT_FORWARD (default: true when service type is ClusterIP)

RELEASE=${RELEASE:-autoptic}
NAMESPACE=${NAMESPACE:-server}
INGRESS_ENABLED=${INGRESS_ENABLED:-false}
API_SVC_TYPE=${API_SVC_TYPE:-ClusterIP}
UI_SVC_TYPE=${UI_SVC_TYPE:-ClusterIP}

SCRIPT_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" >/dev/null 2>&1 && pwd)"
CHART_DIR="${SCRIPT_DIR}/.."
PIDS_FILE="${CHART_DIR}/.port-forward.pids"

echo "[autoptic] Installing/upgrading release '${RELEASE}' into namespace '${NAMESPACE}'"
helm upgrade --install "${RELEASE}" "${CHART_DIR}" \
  -n "${NAMESPACE}" --create-namespace \
  --set baseApp.enabled=false \
  --set ui.ingress.enabled="${INGRESS_ENABLED}" \
  --set api.service.type="${API_SVC_TYPE}" \
  --set ui.service.type="${UI_SVC_TYPE}"

echo "[autoptic] Waiting for deployments to roll out..."
kubectl -n "${NAMESPACE}" rollout status deploy/api-deployment || true
kubectl -n "${NAMESPACE}" rollout status deploy/ui-deployment || true
kubectl -n "${NAMESPACE}" rollout status deploy/metrics-deployment || true
kubectl -n "${NAMESPACE}" rollout status deploy/vectors-embedding || true
kubectl -n "${NAMESPACE}" rollout status deploy/scheduler-deployment || true

# Port-forward if using ClusterIP services
PORT_FORWARD=${PORT_FORWARD:-}
if [[ -z "${PORT_FORWARD}" ]]; then
  if [[ "${API_SVC_TYPE}" == "ClusterIP" || "${UI_SVC_TYPE}" == "ClusterIP" ]]; then
    PORT_FORWARD=true
  else
    PORT_FORWARD=false
  fi
fi

if [[ "${PORT_FORWARD}" == "true" ]]; then
  echo "[autoptic] Starting port-forwards (stored in ${PIDS_FILE})"
  : > "${PIDS_FILE}"
  if [[ "${UI_SVC_TYPE}" == "ClusterIP" ]]; then
    echo "[autoptic] UI -> http://127.0.0.1:8080"
    kubectl -n "${NAMESPACE}" port-forward svc/ui-service 8080:8080 >/dev/null 2>&1 &
    echo $! >> "${PIDS_FILE}"
  fi
  if [[ "${API_SVC_TYPE}" == "ClusterIP" ]]; then
    echo "[autoptic] API -> http://127.0.0.1:9999"
    kubectl -n "${NAMESPACE}" port-forward svc/api-service 9999:9999 >/dev/null 2>&1 &
    echo $! >> "${PIDS_FILE}"
  fi
  echo "[autoptic] To stop port-forwards: xargs kill < ${PIDS_FILE} || true"
fi

echo "[autoptic] Done."

