#!/usr/bin/env bash
# Tekton Pipelines/Triggers/Dashboard install, and the HTTPRoute that exposes
# the Dashboard at tekton.lab.devkit.

setup_tekton() {
  info "Installing Tekton Pipeline, Triggers, and Dashboard..."
  kubectl apply -f "https://infra.tekton.dev/tekton-releases/pipeline/previous/${TEKTON_PIPELINE_VERSION}/release.yaml"
  kubectl apply -f "https://infra.tekton.dev/tekton-releases/triggers/previous/${TEKTON_TRIGGERS_VERSION}/release.yaml"
  kubectl wait --for=condition=Established --timeout=30s crds/clusterinterceptors.triggers.tekton.dev || true
  kubectl apply -f "https://infra.tekton.dev/tekton-releases/triggers/previous/${TEKTON_TRIGGERS_VERSION}/interceptors.yaml" || true
  kubectl apply -f "https://infra.tekton.dev/tekton-releases/dashboard/previous/${TEKTON_DASHBOARD_VERSION}/release-full.yaml"

  info "Waiting until Tekton pods are ready..."
  kubectl wait -n tekton-pipelines --for=condition=ready pods --all --timeout=600s

  info "Creating HTTPRoute for Tekton Dashboard (tekton.lab.devkit)..."
  kubectl apply -f "${SCRIPT_DIR}/tekton/httproute.yaml"
}
