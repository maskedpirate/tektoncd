#!/usr/bin/env bash
# Self-hosted Gitea: lightweight (sqlite/in-memory) single-pod install via
# the official Helm chart, exposed at gitea.lab.devkit, with admin
# credentials generated once and mirrored into the default namespace so
# Tekton Task workspaces there can use them (Secrets don't cross namespaces).

setup_gitea() {
  info "Installing Gitea..."
  helm repo add gitea-charts https://dl.gitea.com/charts/ >/dev/null
  helm repo update gitea-charts >/dev/null

  kubectl create namespace gitea --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  if ! kubectl get secret gitea-admin-secret -n gitea >/dev/null 2>&1; then
    info "Generating Gitea admin credentials (secret gitea-admin-secret in ns gitea)..."
    # openssl rand is a bounded generator, unlike /dev/urandom -- piping the
    # latter into `head -c` sends the upstream a SIGPIPE that `set -o
    # pipefail` treats as the whole pipeline failing.
    GITEA_ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 20)
    kubectl create secret generic gitea-admin-secret -n gitea \
      --from-literal=username=gitea_admin \
      --from-literal=password="${GITEA_ADMIN_PASSWORD}" \
      --from-literal=email=gitea@lab.devkit
  fi
  GITEA_ADMIN_PASSWORD=$(kubectl get secret gitea-admin-secret -n gitea -o jsonpath='{.data.password}' | base64 -d)

  # Mirror the admin credentials into the default namespace so Tekton Task
  # workspaces there (git-clone) can mount them.
  kubectl get secret gitea-admin-secret -n gitea -o json | \
    jq '{apiVersion, kind, type, data, metadata: {name: "gitea-credentials", namespace: "default"}}' | \
    kubectl apply -f - >/dev/null

  helm upgrade --install gitea gitea-charts/gitea \
    --namespace gitea \
    -f "${SCRIPT_DIR}/gitea/values.yaml" \
    --wait --timeout 5m

  info "Creating HTTPRoute for Gitea (gitea.lab.devkit)..."
  kubectl apply -f "${SCRIPT_DIR}/gitea/httproute.yaml"
}
