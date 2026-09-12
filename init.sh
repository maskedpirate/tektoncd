#!/usr/bin/env bash
set -e -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare TEKTON_PIPELINE_VERSION TEKTON_TRIGGERS_VERSION TEKTON_DASHBOARD_VERSION CONTAINER_RUNTIME
declare CLUSTER_NAME STATIC_IP DOCKER_SUBNET

# Deploys a local Tekton CI/CD lab on a kind cluster: Envoy Gateway as the
# single ingress point, Tekton Pipelines/Triggers/Dashboard, a self-hosted
# Gitea that triggers pipelines via webhook, a local image registry, and a
# UI for it. See CLAUDE.md for the full architecture.
#
# Each stage below (lib/*.sh) is idempotent, so this script is safe to
# re-run any time -- after a small manifest tweak, or against a fully wiped
# cluster (verified: kind delete cluster + remove the registry container and
# the kind network, then ./init.sh, rebuilds everything from nothing).

# Prerequisites:
# - podman or docker (recommended 8GB memory config)
# - kind
# - kubectl
# - helm
# - jq
# - envsubst (gettext)

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "This script is not intended to be sourced. Please run it as ./init.sh"
  return 1
fi

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/kind.sh"
source "${SCRIPT_DIR}/lib/envoy.sh"
source "${SCRIPT_DIR}/lib/tekton.sh"
source "${SCRIPT_DIR}/lib/registry.sh"
source "${SCRIPT_DIR}/lib/gitea.sh"
source "${SCRIPT_DIR}/lib/ci.sh"

show-usage() {
  echo "Usage:"
  echo "    init.sh [-c cluster-name] [-i static-ip] [-s subnet] [-p pipeline-version] [-t triggers-version] [-d dashboard-version] [-k]"
  echo "    init.sh -h"
  echo "        -c    KinD cluster name (default: tekton)"
  echo "        -i    Static IP for control plane (default: 172.24.0.10)"
  echo "        -s    Docker network subnet for kind (default: 172.24.0.0/16)"
  echo "        -k    Force Podman container runtime instead of Docker"
  echo "        -h    Print this help message and exit"
}

# Read command line options
while getopts ":c:i:s:p:t:d:kh" opt; do
  case ${opt} in
    c ) CLUSTER_NAME=$OPTARG ;;
    i ) STATIC_IP=$OPTARG ;;
    s ) DOCKER_SUBNET=$OPTARG ;;
    p ) TEKTON_PIPELINE_VERSION=$OPTARG ;;
    t ) TEKTON_TRIGGERS_VERSION=$OPTARG ;;
    d ) TEKTON_DASHBOARD_VERSION=$OPTARG ;;
    k ) CONTAINER_RUNTIME="podman" ;;
    h ) show-usage; exit 0 ;;
    \? ) echo "Invalid option: -$OPTARG" 1>&2; show-usage; exit 1 ;;
    : ) echo "Option -$OPTARG requires an argument" 1>&2; show-usage; exit 1 ;;
  esac
done
shift $((OPTIND -1))

# Default configurations
export KIND_CLUSTER_NAME=${CLUSTER_NAME:-"tekton"}
CONTROL_PLANE_STATIC_IP=${STATIC_IP:-"172.24.0.10"}
KIND_NET_SUBNET=${DOCKER_SUBNET:-"172.24.0.0/16"}
ENVOY_VERSION="1.9.1"
reg_name='kind-registry'
reg_port='5000'

# Setup custom kubeconfig location for this session and child commands
KUBECONFIG_DIR="${HOME}/.kube/configs"
mkdir -p "${KUBECONFIG_DIR}"
export KUBECONFIG="${KUBECONFIG_DIR}/kind-${KIND_CLUSTER_NAME}.yaml"

if [ -z "$TEKTON_PIPELINE_VERSION" ]; then
  TEKTON_PIPELINE_VERSION=$(get_latest_release tektoncd/pipeline)
fi
if [ -z "$TEKTON_TRIGGERS_VERSION" ]; then
  TEKTON_TRIGGERS_VERSION=$(get_latest_release tektoncd/triggers)
fi
if [ -z "$TEKTON_DASHBOARD_VERSION" ]; then
  TEKTON_DASHBOARD_VERSION=$(get_latest_release tektoncd/dashboard)
fi
if [ -z "$CONTAINER_RUNTIME" ]; then
  CONTAINER_RUNTIME="docker"
fi

info "Using container runtime: $CONTAINER_RUNTIME"
info "Target kubeconfig: $KUBECONFIG"

setup_network
setup_registry_container
setup_kind_cluster
setup_static_ip_and_nat
setup_envoy_gateway
setup_tekton
wait_for_envoy_dataplane
bridge_local_registry
deploy_registry_ui
setup_gitea
apply_ci_pipelines
bootstrap_gitea_repo

print_summary
