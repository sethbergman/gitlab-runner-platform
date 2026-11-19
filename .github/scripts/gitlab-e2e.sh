#!/usr/bin/env bash
# End-to-end test against a real GitLab: a GitLab CE container serves the
# projects the autoscaler is configured for, the autoscaler (the pinned
# release image) reads their queue, and each tenant's runner, installed from
# its committed values and pinned chart, runs that tenant's jobs as pods in
# its own namespace.
#
# Needs a kind cluster as the current kubectl context, plus docker, kubectl,
# helm, jq, openssl and curl. `make gitlab-e2e` creates the cluster and tears
# everything down afterwards. Run from the repository root.
#
# Changed for the test, and nothing else: GitLab's URL (gitlab.e2e.test, over
# HTTPS with a throwaway CA, so the autoscaler's 443-only egress policy is
# exercised as written) and the CA each component trusts. The tenant
# namespaces carry the Pod Security labels the Terraform module sets.
set -euo pipefail

GITLAB_VERSION=$(cat .github/versions/gitlab)
GITLAB_HOST=gitlab.e2e.test
GITLAB_PORT=${GITLAB_HOST_PORT:-8443}
CONTAINER=${GITLAB_CONTAINER:-gitlab-e2e}
WORK=$(mktemp -d)
PF_PID=

log() { printf '\n== %s\n' "$*"; }

diagnose() {
  set +e
  log "diagnostics"
  kubectl get pods -A -o wide
  kubectl -n gitlab-runner-system logs deploy/warmpool-autoscaler --tail=30 2>/dev/null
  for d in gitops/tenants/*/; do
    t=$(basename "${d}")
    kubectl -n "ci-${t}" get events --sort-by=.lastTimestamp 2>/dev/null | tail -15
    kubectl -n "ci-${t}" logs deploy/gitlab-runner --tail=30 2>/dev/null
  done
  docker logs --tail 40 "${CONTAINER}" 2>&1
}
cleanup() {
  rc=$?
  [ -n "${PF_PID}" ] && kill "${PF_PID}" 2>/dev/null
  [ "${rc}" != 0 ] && diagnose
  rm -rf "${WORK}"
  exit "${rc}"
}
trap cleanup EXIT

wait_for() { # seconds description command...
  local deadline=$((SECONDS + $1)) what=$2
  shift 2
  until "$@"; do
    if [ "${SECONDS}" -ge "${deadline}" ]; then echo "timed out waiting for ${what}"; return 1; fi
    sleep 5
  done
}

api() { # method path [curl args...]
  local method=$1 path=$2
  shift 2
  curl -fsS --resolve "${GITLAB_HOST}:${GITLAB_PORT}:127.0.0.1" --cacert "${WORK}/ca.crt" \
    -H "PRIVATE-TOKEN: ${ROOT_TOKEN}" -X "${method}" "https://${GITLAB_HOST}:${GITLAB_PORT}/api/v4${path}" "$@"
}

# The projects the autoscaler serves, as committed. Each project's group is
# the tenant that runs its jobs, so every group must be a tenant.
PROJECTS=$(grep -oE 'GITLAB_PROJECTS: "[^"]+"' deploy/autoscaler/deployment.yaml | cut -d'"' -f2 | tr ',' ' ')
for p in ${PROJECTS}; do
  [ -d "gitops/tenants/${p%%/*}" ] || { echo "project ${p}: no tenant ${p%%/*} under gitops/tenants"; exit 1; }
done
echo "projects: ${PROJECTS}"

log "throwaway CA and a certificate for ${GITLAB_HOST}"
mkdir -p "${WORK}/ssl"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=gitlab-e2e-ca \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign \
  -keyout "${WORK}/ca.key" -out "${WORK}/ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=${GITLAB_HOST}" \
  -keyout "${WORK}/ssl/${GITLAB_HOST}.key" -out "${WORK}/server.csr" 2>/dev/null
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "${GITLAB_HOST}" > "${WORK}/ext"
openssl x509 -req -in "${WORK}/server.csr" -CA "${WORK}/ca.crt" -CAkey "${WORK}/ca.key" -CAcreateserial \
  -days 2 -extfile "${WORK}/ext" -out "${WORK}/ssl/${GITLAB_HOST}.crt" 2>/dev/null

log "GitLab CE ${GITLAB_VERSION} on the kind network"
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER}" --network kind --hostname "${GITLAB_HOST}" --shm-size 256m \
  -p "127.0.0.1:${GITLAB_PORT}:443" -v "${WORK}/ssl:/etc/gitlab/ssl" \
  -e GITLAB_OMNIBUS_CONFIG="
    external_url 'https://${GITLAB_HOST}'
    letsencrypt['enable'] = false
    nginx['listen_port'] = 443
    gitlab_rails['initial_root_password'] = '$(openssl rand -hex 16)'
    gitlab_rails['usage_ping_enabled'] = false
    prometheus_monitoring['enable'] = false
    puma['worker_processes'] = 0
    sidekiq['concurrency'] = 5
    registry['enable'] = false
    gitlab_kas['enable'] = false
  " "gitlab/gitlab-ce:${GITLAB_VERSION}" >/dev/null
IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${CONTAINER}")
echo "container IP ${IP}"

log "CoreDNS resolves ${GITLAB_HOST} to the container"
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' |
  awk -v ip="${IP}" -v host="${GITLAB_HOST}" \
    '/^ *forward / && !done { print "    hosts {\n        " ip " " host "\n        fallthrough\n    }"; done=1 } { print }' \
  > "${WORK}/Corefile"
kubectl -n kube-system patch configmap coredns --type merge \
  -p "$(jq -n --rawfile c "${WORK}/Corefile" '{data: {Corefile: $c}}')" >/dev/null
kubectl -n kube-system rollout restart deploy/coredns >/dev/null
kubectl -n kube-system rollout status deploy/coredns --timeout=120s

# The image's own healthcheck turns healthy while the database schema is still
# loading, so wait for omnibus to finish configuring and for Rails to serve.
# (grep reads the whole log: an early exit would fail the pipe under pipefail.)
ready() {
  docker logs "${CONTAINER}" 2>&1 | grep 'gitlab Reconfigured!' >/dev/null &&
    curl -fsS -o /dev/null --resolve "${GITLAB_HOST}:${GITLAB_PORT}:127.0.0.1" --cacert "${WORK}/ca.crt" \
      "https://${GITLAB_HOST}:${GITLAB_PORT}/users/sign_in"
}
log "waiting for GitLab to boot (several minutes)"
wait_for 900 "GitLab to serve" ready
echo "GitLab serving after ${SECONDS}s"

log "tokens: api for setup, read_api for the autoscaler (the scope its docs ask for)"
ROOT_TOKEN="glpat-e2e$(openssl rand -hex 12)"
READ_TOKEN="glpat-e2e$(openssl rand -hex 12)"
docker exec "${CONTAINER}" gitlab-rails runner "
  root = User.find_by_username('root')
  { 'e2e-setup' => ['${ROOT_TOKEN}', [:api]], 'e2e-autoscaler' => ['${READ_TOKEN}', [:read_api]] }.each do |name, (value, scopes)|
    t = root.personal_access_tokens.build(name: name, scopes: scopes, expires_at: 2.days.from_now)
    t.organization_id = root.organizations.first&.id || Organizations::Organization.first.id if t.respond_to?(:organization_id=)
    t.set_token(value)
    t.save!
  end
"
wait_for 120 "API" api GET /version -o /dev/null
api GET /version | jq -c .

log "groups, projects and one pipeline each, before any runner exists"
declare -A GROUP_ID PROJECT_ID
cat > "${WORK}/ci.yml" <<'YAML'
e2e:
  script:
    - echo "job ${CI_JOB_ID} for ${CI_PROJECT_PATH} on $(hostname)"
    - grep PRETTY_NAME /etc/os-release
YAML
for p in ${PROJECTS}; do
  g=${p%%/*}
  if [ -z "${GROUP_ID[$g]:-}" ]; then
    GROUP_ID[$g]=$(api POST /groups -d "name=${g}" -d "path=${g}" -d visibility=private | jq -r .id)
  fi
  PROJECT_ID[$p]=$(api POST /projects -d "name=${p#*/}" -d "path=${p#*/}" -d "namespace_id=${GROUP_ID[$g]}" | jq -r .id)
  api POST "/projects/${PROJECT_ID[$p]}/repository/files/%2Egitlab-ci%2Eyml" -d branch=main \
    -d commit_message="CI for the e2e" --data-urlencode "content@${WORK}/ci.yml" -o /dev/null
  echo "${p}: project ${PROJECT_ID[$p]} in group ${GROUP_ID[$g]}"
done
pending_total() {
  local n=0 p
  for p in ${PROJECTS}; do
    n=$((n + $(api GET "/projects/${PROJECT_ID[$p]}/jobs?scope%5B%5D=pending" | jq length)))
  done
  echo "${n}"
}
EXPECTED=$(wc -w <<<"${PROJECTS}")
all_pending() { [ "$(pending_total)" = "${EXPECTED}" ]; }
wait_for 180 "${EXPECTED} pending jobs" all_pending
echo "${EXPECTED} jobs pending in GitLab"

log "autoscaler: committed manifests, URL and CA swapped, read_api token"
kubectl label node --all workload=ci --overwrite >/dev/null
kubectl kustomize deploy/autoscaler | kubectl apply -f - >/dev/null
kubectl -n gitlab-runner-system create secret generic warmpool-gitlab-token --from-literal=token="${READ_TOKEN}"
kubectl -n gitlab-runner-system create configmap gitlab-e2e-ca --from-file=ca.crt="${WORK}/ca.crt"
kubectl -n gitlab-runner-system patch configmap warmpool-autoscaler --type merge \
  -p "{\"data\":{\"GITLAB_URL\":\"https://${GITLAB_HOST}\"}}"
kubectl -n gitlab-runner-system patch deploy warmpool-autoscaler --type json -p '[
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"gitlab-e2e-ca","configMap":{"name":"gitlab-e2e-ca"}}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"gitlab-e2e-ca","mountPath":"/etc/gitlab-e2e","readOnly":true}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"SSL_CERT_FILE","value":"/etc/gitlab-e2e/ca.crt"}}
]'
kubectl -n gitlab-runner-system rollout status deploy/warmpool-autoscaler --timeout=180s
kubectl -n gitlab-runner-system port-forward deploy/warmpool-autoscaler 18080:8080 >/dev/null 2>&1 &
PF_PID=$!
metric() { curl -fsS localhost:18080/metrics 2>/dev/null | awk -v m="$1" '$1 == m { print $2 }'; }
sees_queue() { [ "$(metric warmpool_pending_jobs)" = "${EXPECTED}" ]; }
wait_for 120 "the autoscaler to report ${EXPECTED} pending jobs" sees_queue
pool_sized() {
  local desired replicas
  desired=$(metric warmpool_desired_replicas)
  replicas=$(kubectl -n gitlab-runner-system get deploy/runner-warm-pool -o jsonpath='{.spec.replicas}')
  [ -n "${desired}" ] && [ "${desired}" -ge "${EXPECTED}" ] && [ "${replicas}" = "${desired}" ]
}
wait_for 120 "the warm pool to be sized for the queue" pool_sized
echo "autoscaler: pending $(metric warmpool_pending_jobs), business hours $(metric warmpool_business_schedule_active), warm pool $(metric warmpool_desired_replicas) replicas"
test "$(metric 'warmpool_errors_total{stage="queue"}')" = 0 || { echo "queue errors after the first read"; exit 1; }

log "one group runner per tenant, installed from its committed values and chart"
declare -A RUNNER_ID
for d in gitops/tenants/*/; do
  t=$(basename "${d}")
  [ -n "${GROUP_ID[$t]:-}" ] || { echo "tenant ${t} has no project in GITLAB_PROJECTS; skipping"; continue; }
  chart=$(jq -r .chartVersion "${d}config.json")
  created=$(api POST /user/runners -d runner_type=group_type -d "group_id=${GROUP_ID[$t]}" \
    -d "description=${t}" -d tag_list=docker,linux -d run_untagged=true)
  RUNNER_ID[$t]=$(jq -r .id <<<"${created}")
  kubectl create namespace "ci-${t}" >/dev/null
  kubectl label namespace "ci-${t}" "platform.ci/tenant=${t}" \
    pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/audit=restricted >/dev/null
  kubectl -n "ci-${t}" create secret generic gitlab-runner-token \
    --from-literal=runner-token="$(jq -r .token <<<"${created}")" --from-literal=runner-registration-token= >/dev/null
  kubectl -n "ci-${t}" create secret generic gitlab-e2e-certs --from-file="${GITLAB_HOST}.crt=${WORK}/ca.crt" >/dev/null
  echo "${t}: runner ${RUNNER_ID[$t]}, chart ${chart}"
  helm install gitlab-runner gitlab-runner --repo https://charts.gitlab.io --version "${chart}" \
    --namespace "ci-${t}" -f "${d}values.yaml" \
    --set gitlabUrl="https://${GITLAB_HOST}" --set certsSecretName=gitlab-e2e-certs \
    --wait --timeout 5m >/dev/null
done

log "every pipeline succeeds, each job on its tenant's runner in its tenant's namespace"
pipeline_status() { api GET "/projects/${PROJECT_ID[$1]}/pipelines?per_page=1" | jq -r '.[0].status'; }
finished() {
  local p s
  for p in ${PROJECTS}; do
    s=$(pipeline_status "${p}")
    case "${s}" in success) ;; failed | canceled | skipped) echo "${p}: pipeline ${s}"; return 0 ;; *) return 1 ;; esac
  done
}
wait_for 900 "pipelines to finish" finished
failures=0
for p in ${PROJECTS}; do
  t=${p%%/*}
  job=$(api GET "/projects/${PROJECT_ID[$p]}/jobs" | jq '.[0]')
  id=$(jq -r .id <<<"${job}")
  trace=$(api GET "/projects/${PROJECT_ID[$p]}/jobs/${id}/trace")
  status=$(jq -r .status <<<"${job}")
  runner=$(jq -r .runner.id <<<"${job}")
  echo "${p}: job ${id} ${status} on runner ${runner} (tenant ${t} is ${RUNNER_ID[$t]})"
  grep -E "Using Kubernetes namespace|PRETTY_NAME|Job succeeded" <<<"${trace}" | sed 's/^/    /'
  [ "${status}" = success ] || failures=$((failures + 1))
  [ "${runner}" = "${RUNNER_ID[$t]}" ] || { echo "    ran on another tenant's runner"; failures=$((failures + 1)); }
  grep -q "Using Kubernetes namespace: ci-${t}" <<<"${trace}" || { echo "    not in namespace ci-${t}"; failures=$((failures + 1)); }
done
[ "${failures}" = 0 ] || { echo "${failures} failed checks"; exit 1; }

drained() { [ "$(metric warmpool_pending_jobs)" = 0 ]; }
wait_for 120 "the autoscaler to see the queue drain" drained
echo "autoscaler: pending 0 once the jobs ran"
log "passed"
