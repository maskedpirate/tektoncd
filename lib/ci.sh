#!/usr/bin/env bash
# Applies the Tekton Task/Pipeline/Trigger manifests, then bootstraps the
# Gitea org/repo/seed/webhook that wires a push to Gitea into a PipelineRun.

apply_ci_pipelines() {
  info "Applying hello-world Task/Pipeline (trivial echo example)..."
  kubectl apply -f "${SCRIPT_DIR}/pipelines/hello-world/hello-task.yaml"
  kubectl apply -f "${SCRIPT_DIR}/pipelines/hello-world/hello-pipeline.yaml"

  info "Applying hello-world-ci Tasks/Pipeline (git-clone, maven build/test, kaniko build+push)..."
  kubectl apply -f "${SCRIPT_DIR}/pipelines/hello-world-ci/"

  info "Applying EventListener RBAC and Gitea trigger (TriggerBinding/TriggerTemplate/EventListener)..."
  kubectl apply -f "${SCRIPT_DIR}/triggers/rbac.yaml"
  kubectl apply -f "${SCRIPT_DIR}/triggers/gitea-trigger.yaml"

  info "Waiting for the Gitea EventListener to be ready..."
  kubectl wait --for=condition=ready pod -l eventlistener=gitea-listener -n default --timeout=180s
}

bootstrap_gitea_repo() {
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
    cp -r "${SCRIPT_DIR}/sample-repos/hello-world/." "${SEED_DIR}/"
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
}
