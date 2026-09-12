#!/usr/bin/env bash
# Envoy Gateway: the Helm-installed controller, the EnvoyProxy/GatewayClass
# pinning its data plane to the ingress-ready node with hostNetwork, and the
# root Gateway every HTTPRoute in this repo attaches to.

setup_envoy_gateway() {
  info "Deploying Envoy Gateway..."
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version "v${ENVOY_VERSION}" \
    --namespace envoy-gateway-system \
    --create-namespace \
    -f "${SCRIPT_DIR}/envoy/values.yaml"

  info "Waiting for Envoy Gateway controller to be ready..."
  kubectl wait --namespace envoy-gateway-system \
    --for=condition=ready pod \
    --selector=control-plane=envoy-gateway \
    --timeout=180s

  info "Configuring EnvoyProxy data plane pinning and GatewayClass..."
  kubectl apply -f "${SCRIPT_DIR}/envoy/envoyproxy.yaml"

  info "Creating root Gateway resource (devkit-gateway)..."
  kubectl apply -f "${SCRIPT_DIR}/envoy/gateway.yaml"
}

wait_for_envoy_dataplane() {
  info "Waiting for Envoy data-plane proxy pod to be ready..."
  kubectl wait --namespace envoy-gateway-system \
    --for=condition=ready pod \
    --selector=gateway.envoyproxy.io/owning-gateway-name=devkit-gateway \
    --timeout=180s
}
