#!/usr/bin/env bash
set -e -o pipefail

declare TEKTON_PIPELINE_VERSION TEKTON_TRIGGERS_VERSION TEKTON_DASHBOARD_VERSION CONTAINER_RUNTIME
declare CLUSTER_NAME STATIC_IP DOCKER_SUBNET

# This script deploys Tekton on a local kind cluster
# It creates a kind cluster with a static IP assigned to the control plane,
# installs Envoy Gateway via OCI Helm chart, and configures an HTTPRoute for the Tekton Dashboard.

# Prerequisites:
# - podman or docker (recommended 8GB memory config)
# - kind
# - kubectl
# - helm
# - jq

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "This script is not intended to be sourced. Please run it as ./init.sh"
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
    -e REGISTRY_STORAGE_DELETE_ENABLED=true \
    registry:2
fi
info "Registry ready..."

# 3. Create KinD Cluster
info "Checking if kind cluster '$KIND_CLUSTER_NAME' exists..."
export KIND_EXPERIMENTAL_PROVIDER=$CONTAINER_RUNTIME
running_cluster=$(kind get clusters 2>/dev/null | grep -w "$KIND_CLUSTER_NAME" || true)

if [ "${running_cluster}" != "$KIND_CLUSTER_NAME" ]; then
  info "Kind cluster '$KIND_CLUSTER_NAME' does not exist, creating..."

  cat <<EOF | kind create cluster --image kindest/node:v1.36.1 --name "$KIND_CLUSTER_NAME" --config=-
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

  info "Waiting for all cluster nodes to become ready..."
  kubectl wait --for=condition=ready node --all --timeout=600s
fi
info "Kind cluster '$KIND_CLUSTER_NAME' is running."

# 4. Attach deterministic static alias IP and NAT redirect rules to control plane
cp_container="${KIND_CLUSTER_NAME}-control-plane"
info "Ensuring static alias IP ${CONTROL_PLANE_STATIC_IP} on ${cp_container}..."
"$CONTAINER_RUNTIME" exec "${cp_container}" bash -c \
  "ip addr show dev eth0 | grep -q '${CONTROL_PLANE_STATIC_IP}/' || ip addr add '${CONTROL_PLANE_STATIC_IP}/16' dev eth0"

info "Ensuring port 80 -> 10080 NAT redirect inside ${cp_container}..."
"$CONTAINER_RUNTIME" exec "${cp_container}" bash -c \
  "iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 10080 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 10080"
"$CONTAINER_RUNTIME" exec "${cp_container}" bash -c \
  "iptables -t nat -C OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-ports 10080 2>/dev/null || iptables -t nat -A OUTPUT -p tcp -o lo --dport 80 -j REDIRECT --to-ports 10080"

# Ensure registry is attached to kind network
"$CONTAINER_RUNTIME" network connect kind "${reg_name}" >/dev/null 2>&1 || true

# 5. Install Envoy Gateway via OCI registry
info "Deploying Envoy Gateway..."
cat <<EOF | helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "v${ENVOY_VERSION}" \
  --namespace envoy-gateway-system \
  --create-namespace \
  -f -
deployment:
  nodeSelector:
    ingress-ready: "yes"
  tolerations:
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Exists"
      effect: "NoSchedule"
EOF

info "Waiting for Envoy Gateway controller to be ready..."
kubectl wait --namespace envoy-gateway-system \
  --for=condition=ready pod \
  --selector=control-plane=envoy-gateway \
  --timeout=180s

# 6. Configure the Proxy Data Plane via EnvoyProxy CRD
info "Configuring EnvoyProxy data plane pinning and hostNetwork..."
cat <<EOF | kubectl apply -f -
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: devkit-proxy-config
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        patch:
          type: StrategicMerge
          value:
            spec:
              template:
                spec:
                  hostNetwork: true
                  dnsPolicy: ClusterFirstWithHostNet
        pod:
          nodeSelector:
            ingress-ready: "yes"
          tolerations:
            - key: "node-role.kubernetes.io/control-plane"
              operator: "Exists"
              effect: "NoSchedule"
      envoyService:
        type: ClusterIP
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: devkit-proxy-config
    namespace: envoy-gateway-system
EOF

# 7. Create root Gateway resource
info "Creating root Gateway resource (devkit-gateway)..."
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: devkit-gateway
  namespace: default
spec:
  gatewayClassName: eg
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
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: tekton-dashboard
      port: 9097
EOF

info "Waiting for Envoy data-plane proxy pod to be ready..."
kubectl wait --namespace envoy-gateway-system \
  --for=condition=ready pod \
  --selector=gateway.envoyproxy.io/owning-gateway-name=devkit-gateway \
  --timeout=180s

# 10. Bridge the host-side local registry container into the cluster as a
# stable Kubernetes Service, so in-cluster pods (kaniko) can push to it by a
# resolvable DNS name. The registry is a plain docker container, not a k8s
# object, so pods can't resolve its bare hostname via cluster DNS (ndots
# search-domain rules never fall through to a plain single-label name) --
# an Endpoints object pointing at its container IP works around that.
info "Wiring local registry into the cluster as local-registry.default.svc.cluster.local..."
REGISTRY_IP=$("$CONTAINER_RUNTIME" inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${reg_name}")
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: local-registry
  namespace: default
spec:
  ports:
    - port: 5000
      targetPort: 5000
---
apiVersion: v1
kind: Endpoints
metadata:
  name: local-registry
  namespace: default
subsets:
  - addresses:
      - ip: ${REGISTRY_IP}
    ports:
      - port: 5000
EOF

# 11. Deploy a UI for the local registry (registry.lab.devkit)
info "Deploying registry UI..."
kubectl apply -f "$(dirname "$0")/registry-ui/registry-ui.yaml"
kubectl apply -f "$(dirname "$0")/registry-ui/httproute.yaml"
kubectl rollout status deployment/registry-ui -n default --timeout=120s

# 12. Install Gitea (in-cluster git host, used to trigger pipelines via webhook)
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
# workspaces there (git-clone) can mount them -- Secrets don't cross namespaces.
kubectl get secret gitea-admin-secret -n gitea -o json | \
  jq '{apiVersion, kind, type, data, metadata: {name: "gitea-credentials", namespace: "default"}}' | \
  kubectl apply -f - >/dev/null

helm upgrade --install gitea gitea-charts/gitea \
  --namespace gitea \
  -f "$(dirname "$0")/gitea/values.yaml" \
  --wait --timeout 5m

info "Creating HTTPRoute for Gitea (gitea.lab.devkit)..."
kubectl apply -f "$(dirname "$0")/gitea/httproute.yaml"

# 13. Install the hello-world Tasks/Pipelines and the Gitea -> Tekton Triggers wiring
info "Applying hello-world Task/Pipeline (trivial echo example)..."
kubectl apply -f "$(dirname "$0")/pipelines/hello-world/hello-task.yaml"
kubectl apply -f "$(dirname "$0")/pipelines/hello-world/hello-pipeline.yaml"

info "Applying hello-world-ci Tasks/Pipeline (git-clone, maven build/test, kaniko build+push)..."
kubectl apply -f "$(dirname "$0")/pipelines/hello-world-ci/"

info "Applying EventListener RBAC and Gitea trigger (TriggerBinding/TriggerTemplate/EventListener)..."
kubectl apply -f "$(dirname "$0")/triggers/rbac.yaml"
kubectl apply -f "$(dirname "$0")/triggers/gitea-trigger.yaml"

info "Waiting for the Gitea EventListener to be ready..."
kubectl wait --for=condition=ready pod -l eventlistener=gitea-listener -n default --timeout=180s

# 14. Bootstrap a Gitea org/repo and an org-level webhook pointed at the EventListener
GITEA_AUTH="gitea_admin:${GITEA_ADMIN_PASSWORD}"
GITEA_ORG="tekton-lab"
GITEA_REPO="hello-world"
EL_URL="http://el-gitea-listener.default.svc.cluster.local:8080/"

info "Ensuring Gitea org '${GITEA_ORG}' exists..."
curl -s -u "${GITEA_AUTH}" -H "Host: gitea.lab.devkit" -H "Content-Type: application/json" \
  -d "{\"username\":\"${GITEA_ORG}\",\"visibility\":\"private\"}" \
  "http://${CONTROL_PLANE_STATIC_IP}/api/v1/orgs" >/dev/null

info "Ensuring Gitea repo '${GITEA_ORG}/${GITEA_REPO}' exists..."
curl -s -u "${GITEA_AUTH}" -H "Host: gitea.lab.devkit" -H "Content-Type: application/json" \
  -d "{\"name\":\"${GITEA_REPO}\",\"auto_init\":true,\"default_branch\":\"main\"}" \
  "http://${CONTROL_PLANE_STATIC_IP}/api/v1/orgs/${GITEA_ORG}/repos" >/dev/null

info "Seeding Gitea repo with sample-repos/hello-world (skipped if already seeded)..."
already_seeded=$(curl -s -o /dev/null -w '%{http_code}' -u "${GITEA_AUTH}" -H "Host: gitea.lab.devkit" \
  "http://${CONTROL_PLANE_STATIC_IP}/api/v1/repos/${GITEA_ORG}/${GITEA_REPO}/contents/pom.xml")
if [ "${already_seeded}" != "200" ]; then
  SEED_DIR=$(mktemp -d)
  cp -r "$(dirname "$0")/sample-repos/hello-world/." "${SEED_DIR}/"
  AUTH_HEADER="Authorization: Basic $(printf '%s' "${GITEA_AUTH}" | base64 -w0)"
  git -C "${SEED_DIR}" init -q -b main
  git -C "${SEED_DIR}" -c user.email="tekton-lab@lab.devkit" -c user.name="tekton-lab-bootstrap" add -A
  git -C "${SEED_DIR}" -c user.email="tekton-lab@lab.devkit" -c user.name="tekton-lab-bootstrap" \
    commit -q -m "Seed hello-world Spring Boot app"
  git -C "${SEED_DIR}" remote add origin "http://gitea.lab.devkit/${GITEA_ORG}/${GITEA_REPO}.git"
  git -C "${SEED_DIR}" -c http.extraHeader="${AUTH_HEADER}" fetch origin main -q
  git -C "${SEED_DIR}" -c user.email="tekton-lab@lab.devkit" -c user.name="tekton-lab-bootstrap" \
    merge origin/main --allow-unrelated-histories -q -m "Merge initial Gitea README"
  git -C "${SEED_DIR}" -c http.extraHeader="${AUTH_HEADER}" push origin HEAD:main
  rm -rf "${SEED_DIR}"
else
  info "Gitea repo already has sample content; leaving it alone."
fi

info "Ensuring org webhook -> EventListener exists..."
existing_hook_id=$(curl -s -u "${GITEA_AUTH}" -H "Host: gitea.lab.devkit" \
  "http://${CONTROL_PLANE_STATIC_IP}/api/v1/orgs/${GITEA_ORG}/hooks" | \
  jq -r --arg url "${EL_URL}" '.[] | select(.config.url == $url) | .id' | head -1)
if [ -z "${existing_hook_id}" ]; then
  curl -s -u "${GITEA_AUTH}" -H "Host: gitea.lab.devkit" -H "Content-Type: application/json" \
    -d "{\"type\":\"gitea\",\"config\":{\"url\":\"${EL_URL}\",\"content_type\":\"json\"},\"events\":[\"push\"],\"active\":true}" \
    "http://${CONTROL_PLANE_STATIC_IP}/api/v1/orgs/${GITEA_ORG}/hooks" >/dev/null
fi

info "Setup complete!"
info "Envoy Gateway listening on static IP: ${CONTROL_PLANE_STATIC_IP}:80"
info "Tekton Dashboard routed to: http://tekton.lab.devkit"
info "Gitea routed to: http://gitea.lab.devkit (user: gitea_admin / password: ${GITEA_ADMIN_PASSWORD})"
info "Registry UI routed to: http://registry.lab.devkit"
info "Gitea org/repo: ${GITEA_ORG}/${GITEA_REPO} -- push to 'main' fires the org webhook -> gitea-listener -> hello-world-ci-pipeline (git-clone, mvn build, mvn test, kaniko build+push to local-registry.default.svc.cluster.local:5000/hello-world)"
info "Ensure dnsmasq contains: 'address=/devkit/${CONTROL_PLANE_STATIC_IP}'"
info "To use kubectl in your current shell: export KUBECONFIG=${KUBECONFIG}"

