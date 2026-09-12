#!/usr/bin/env bash
# Docker/podman network, local registry container, kind cluster, and the
# static IP + NAT redirect that let Envoy's hostNetwork listener answer on
# a fixed address.

setup_network() {
  info "Checking bridge network for kind..."
  if ! "$CONTAINER_RUNTIME" network inspect kind >/dev/null 2>&1; then
    info "Creating kind network with subnet ${KIND_NET_SUBNET}..."
    "$CONTAINER_RUNTIME" network create kind \
      --driver bridge \
      --subnet "${KIND_NET_SUBNET}"
  else
    info "Network 'kind' already exists."
  fi
}

setup_registry_container() {
  info "Checking if registry exists..."
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
}

setup_kind_cluster() {
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
}

setup_static_ip_and_nat() {
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
}
