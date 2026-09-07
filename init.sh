#!/usr/bin/env bash
set -e -o pipefail

declare TEKTON_PIPELINE_VERSION TEKTON_TRIGGERS_VERSION TEKTON_DASHBOARD_VERSION CONTAINER_RUNTIME
declare CLUSTER_NAME STATIC_IP DOCKER_SUBNET

# This script deploys Tekton on a local kind cluster
# It creates a kind cluster with a static IP assigned to the control plane,
# installs the standard Kubernetes Gateway API CRDs, deploys Traefik as the Gateway provider,
# and configures an HTTPRoute for the Tekton Dashboard.

# Prerequisites:
# - podman or docker (recommended 8GB memory config)
# - kind
# - kubectl
# - helm

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "This script is not intended to be sourced. Please run it as ./tekton_in_kind.sh"
  return 1
fi

get_latest_release() {
  curl --silent "https://api.github.com/repos/$1/releases/latest" |
    grep '"tag_name":' |
    sed -E 's/.*"([^"]+)".*/\1/'
}

info() {
  echo -e "[\e[93mINFO\e[0m] $1"
}

show-usage() {
  echo "Usage:"
  echo "    tekton_in_kind.sh [-c cluster-name] [-i static-ip] [-s subnet] [-p pipeline-version] [-t triggers-version] [-d dashboard-version] [-k]"
  echo "    tekton_in_kind.sh -h"
  echo "        -c    KinD cluster name (default: tekton)"
  echo "        -i    Static IP for control plane (default: 172.24.0.10)"
  echo "        -s    Docker network subnet for kind (default: 172.24.0.0/16)"
  echo "        -k    Force Docker container runtime instead of Podman"
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
    k ) CONTAINER_RUNTIME="docker" ;;
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
GATEWAY_API_VERSION="v1.1.0"

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
  CONTAINER_RUNTIME="podman"
fi

info "Using container runtime: $CONTAINER_RUNTIME"

# 1. Setup kind network with a fixed subnet if needed
info "Checking bridge network for kind..."
if ! "$CONTAINER_RUNTIME" network inspect kind >/dev/null 2>&1; then
  info "Creating kind network with subnet ${KIND_NET_SUBNET}..."
  "$CONTAINER_RUNTIME" network create kind \
    --driver bridge \
    --subnet "${KIND_NET_SUBNET}"
else
  info "Network 'kind' already exists."
fi

# 2. Local Registry Setup
info "Checking if registry exists..."
reg_name='kind-registry'
reg_port='5000'
running="$(${CONTAINER_RUNTIME} inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)"
if [ "${running}" != 'true' ]; then
  info "Registry does not exist, creating..."
  "$CONTAINER_RUNTIME" rm "${reg_name}" 2> /dev/null || true
  "$CONTAINER_RUNTIME" run \
    -d \
    --restart=always \
    -p "${reg_port}:5000" \
    --network kind \
    --name "${reg_name}" \
    registry:2
fi
info "Registry ready..."

# 3. Create KinD Cluster
info "Checking if kind cluster '$KIND_CLUSTER_NAME' exists..."
export KIND_EXPERIMENTAL_PROVIDER=$CONTAINER_RUNTIME
running_cluster=$(kind get clusters | grep -w "$KIND_CLUSTER_NAME" || true)

KUBECONFIG_DIR="${HOME}/.kube/configs"
mkdir -p "${KUBECONFIG_DIR}"
export KUBECONFIG="${KUBECONFIG_DIR}/kind-${KIND_CLUSTER_NAME}.yaml"

if [ "${running_cluster}" != "$KIND_CLUSTER_NAME" ]; then
  info "Kind cluster '$KIND_CLUSTER_NAME' does not exist, creating..."
  
  cat <<EOF | kind create cluster --name "$KIND_CLUSTER_NAME" --kubeconfig "${KUBECONFIG_DIR}/kind-${KIND_CLUSTER_NAME}.yaml" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=yes"
  - role: worker
  - role: worker
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${reg_port}"]
    endpoint = ["http://${reg_name}:${reg_port}"]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${reg_name}:${reg_port}"]
    endpoint = ["http://${reg_name}:${reg_port}"]
EOF

  # 4. Attach deterministic static alias IP to control plane container
  cp_container="${KIND_CLUSTER_NAME}-control-plane"
  info "Adding static alias IP ${CONTROL_PLANE_STATIC_IP} to ${cp_container}..."

  "$CONTAINER_RUNTIME" exec "${cp_container}" bash -c \
    "ip addr show dev eth0 | grep -q '${CONTROL_PLANE_STATIC_IP}/' || ip addr add '${CONTROL_PLANE_STATIC_IP}/16' dev eth0"

  info "Waiting for all cluster nodes to become ready..."
  kubectl wait --for=condition=ready node --all --timeout=600s

fi
info "Kind cluster '$KIND_CLUSTER_NAME' is running."

# Ensure registry is attached to kind network
"$CONTAINER_RUNTIME" network connect kind "${reg_name}" >/dev/null 2>&1 || true

# 5. Install Kubernetes Gateway API CRDs
info "Installing Kubernetes Gateway API CRDs (${GATEWAY_API_VERSION})..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
kubectl wait --for=condition=Established --timeout=60s crd/gateways.gateway.networking.k8s.io
kubectl wait --for=condition=Established --timeout=60s crd/httproutes.gateway.networking.k8s.io


# 6. Deploy Traefik via Helm with Gateway API enabled
info "Deploying Traefik with Gateway API support..."
helm repo add traefik https://traefik.github.io/charts --force-update
helm repo update

helm upgrade --install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  --set experimental.kubernetesGateway.enabled=true \
  --set ports.web.hostPort=80 \
  --set ports.websecure.hostPort=443 \
  --set nodeSelector."ingress-ready"="yes" \
  --set tolerations[0].key="node-role.kubernetes.io/control-plane" \
  --set tolerations[0].operator="Exists" \
  --set tolerations[0].effect="NoSchedule"

info "Waiting for Traefik to be ready..."
kubectl wait --namespace traefik \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=traefik \
  --timeout=180s

# 7. Create root Gateway resource
info "Creating root Gateway resource (devkit-gateway)..."
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: devkit-gateway
  namespace: default
spec:
  gatewayClassName: traefik
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
EOF

# 8. Install Tekton Components
info "Installing Tekton Pipeline, Triggers, and Dashboard..."
kubectl apply -f "https://infra.tekton.dev/tekton-releases/pipeline/previous/${TEKTON_PIPELINE_VERSION}/release.yaml"
kubectl apply -f "https://infra.tekton.dev/tekton-releases/triggers/previous/${TEKTON_TRIGGERS_VERSION}/release.yaml"
kubectl wait --for=condition=Established --timeout=30s crds/clusterinterceptors.triggers.tekton.dev || true
kubectl apply -f "https://infra.tekton.dev/tekton-releases/triggers/previous/${TEKTON_TRIGGERS_VERSION}/interceptors.yaml" || true
kubectl apply -f "https://infra.tekton.dev/tekton-releases/dashboard/previous/${TEKTON_DASHBOARD_VERSION}/release-full.yaml"

info "Waiting until Tekton pods are ready..."
kubectl wait -n tekton-pipelines --for=condition=ready pods --all --timeout=600s

# 9. Expose Tekton Dashboard via Gateway API HTTPRoute
info "Creating HTTPRoute for Tekton Dashboard (tekton.lab.devkit)..."
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tekton-dashboard
  namespace: tekton-pipelines
spec:
  parentRefs:
  - name: devkit-gateway
    namespace: default
  hostnames:
  - "tekton.lab.devkit"
  rules:
  - backendRefs:
    - name: tekton-dashboard
      port: 9097
EOF

info "Setup complete!"
info "Traefik Gateway listening on static IP: ${CONTROL_PLANE_STATIC_IP}:80"
info "Tekton Dashboard routed to: http://tekton.lab.devkit"
info "Ensure dnsmasq contains: 'address=/devkit/${CONTROL_PLANE_STATIC_IP}'"

