#!/usr/bin/env bash
# Shared helpers used by every stage below.

info() {
  echo -e "[\e[93mINFO\e[0m] $1"
}

get_latest_release() {
  curl --silent "https://api.github.com/repos/$1/releases/latest" |
    grep '"tag_name":' |
    sed -E 's/.*"([^"]+)".*/\1/'
}

print_summary() {
  info "Setup complete!"
  info "Envoy Gateway listening on static IP: ${CONTROL_PLANE_STATIC_IP}:80"
  info "Tekton Dashboard routed to: http://tekton.lab.devkit"
  info "Gitea routed to: http://gitea.lab.devkit (user: gitea_admin / password: ${GITEA_ADMIN_PASSWORD})"
  info "Registry UI routed to: http://registry.lab.devkit"
  info "Gitea org/repo: ${GITEA_ORG}/${GITEA_REPO} -- push to 'main' fires the org webhook -> gitea-listener -> hello-world-ci-pipeline (git-clone, mvn build, mvn test, buildah build+push to local-registry.default.svc.cluster.local:5000/hello-world)"
  info "Ensure dnsmasq contains: 'address=/devkit/${CONTROL_PLANE_STATIC_IP}'"
  info "To use kubectl in your current shell: export KUBECONFIG=${KUBECONFIG}"
}
