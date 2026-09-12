#!/usr/bin/env bash
# Bridges the host-side registry:2 container into the cluster as a stable
# Kubernetes Service (see registry/local-registry.yaml.tmpl for why), and
# deploys a UI for browsing/deleting images at registry.lab.devkit.

bridge_local_registry() {
  info "Wiring local registry into the cluster as local-registry.default.svc.cluster.local..."
  REGISTRY_IP=$("$CONTAINER_RUNTIME" inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${reg_name}")
  export REGISTRY_IP
  envsubst < "${SCRIPT_DIR}/registry/local-registry.yaml.tmpl" | kubectl apply -f -
}

deploy_registry_ui() {
  info "Deploying registry UI..."
  kubectl apply -f "${SCRIPT_DIR}/registry-ui/registry-ui.yaml"
  kubectl apply -f "${SCRIPT_DIR}/registry-ui/httproute.yaml"
  kubectl rollout status deployment/registry-ui -n default --timeout=120s
}
