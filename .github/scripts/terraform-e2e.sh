#!/usr/bin/env bash
# End-to-end test of the runner-fleet module: terraform apply, plan and
# destroy for real, with the Kubernetes and Helm resources on a kind cluster
# and S3, IAM and STS served by moto (terraform/e2e/kind). The mocked
# `terraform test` runs prove what the module renders; this proves the
# providers accept it, the resources come up in an order that works, what
# lands in AWS and the cluster is what the module promises, a second plan
# finds nothing to change, and destroy leaves nothing behind.
#
# Each runner manager must start and stay up: it verifies its token with
# GitLab at startup and exits if that fails, and the module waits for every
# release to be ready. A stand-in (.github/scripts/gitlab-stub.py) answers
# those calls over HTTPS under a throwaway CA, which the runners trust through
# the module's gitlab_ca_secret.
#
# Needs a kind cluster (KIND_CLUSTER, default terraform-e2e) on Docker's
# "kind" network, plus docker, kind, kubectl, jq and openssl. Terraform runs
# in a container on that network, beside moto. `make terraform-e2e` creates
# the cluster and deletes it afterwards. Run from the repository root.
#
# Not covered: IRSA (kind has no OIDC issuer AWS could reach, and moto does
# not enforce IAM) and jobs using the cache (gitlab-e2e.yml runs real jobs
# against a real GitLab).
set -euo pipefail

CLUSTER=${KIND_CLUSTER:-terraform-e2e}
MOTO=${MOTO_CONTAINER:-terraform-e2e-moto}
STUB=${GITLAB_STUB_CONTAINER:-terraform-e2e-gitlab}
GITLAB_HOST=gitlab.e2e.test # gitlab_url in terraform/e2e/kind
ACCOUNT=123456789012        # moto's default account
TERRAFORM_VERSION=$(cat .github/versions/terraform)
MOTO_VERSION=$(cat .github/versions/moto)
WORK=$(mktemp -d)
SYNC_PID=

log() { printf '\n== %s\n' "$*"; }

diagnose() {
  set +e
  log "diagnostics"
  kubectl get pods -A -o wide
  for ns in $(kubectl get ns -l platform.ci/tenant -o jsonpath='{.items[*].metadata.name}'); do
    kubectl -n "${ns}" get events --sort-by=.lastTimestamp | tail -15
    kubectl -n "${ns}" logs deploy/gitlab-runner --tail=20
  done
  docker logs --tail 40 "${MOTO}" 2>&1
  docker logs --tail 20 "${STUB}" 2>&1
}
cleanup() {
  rc=$?
  [ -n "${SYNC_PID}" ] && kill "${SYNC_PID}" 2>/dev/null
  [ "${rc}" != 0 ] && diagnose
  docker rm -f "${MOTO}" "${STUB}" >/dev/null 2>&1
  rm -rf "${WORK}"
  exit "${rc}"
}
trap cleanup EXIT

wait_for() { # seconds description command...
  local deadline=$((SECONDS + $1)) what=$2
  shift 2
  until "$@"; do
    if [ "${SECONDS}" -ge "${deadline}" ]; then echo "timed out waiting for ${what}"; return 1; fi
    sleep 2
  done
}

# Terraform in a container on the kind network, where "moto" and the kind
# control plane resolve. It works on a copy of terraform/ (with the committed
# lock file), so state and the provider cache stay out of the repository.
tf() {
  docker run --rm --network kind -u "$(id -u):$(id -g)" \
    -e HOME=/work -e TF_IN_AUTOMATION=1 -e TF_DATA_DIR=/work/.terraform \
    -e AWS_ACCESS_KEY_ID=moto -e AWS_SECRET_ACCESS_KEY=moto \
    -v "${WORK}:/work" -w /work/src/terraform/e2e/kind \
    "hashicorp/terraform:${TERRAFORM_VERSION}" "$@"
}

# The AWS side, read back with boto3 inside the moto container.
aws_check() { docker exec -i "${MOTO}" python3 - "$@" < .github/scripts/terraform-e2e-aws.py; }
moto_up() {
  docker exec "${MOTO}" python3 -c 'import ssl, urllib.request
urllib.request.urlopen("https://localhost:5000/moto-api/", context=ssl.create_default_context(cafile="/tls/ca.crt"))' 2>/dev/null
}

# A certificate from the throwaway CA, for the given names, into a directory.
issue() { # dir name...
  local dir=$1 sans
  shift
  sans=$(printf 'DNS:%s,' "$@")
  mkdir -p "${dir}"
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$1" -keyout "${dir}/tls.key" -out "${WORK}/server.csr" 2>/dev/null
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "${sans%,}" > "${WORK}/ext"
  openssl x509 -req -in "${WORK}/server.csr" -CA "${WORK}/ca.crt" -CAkey "${WORK}/ca.key" -CAcreateserial \
    -days 2 -extfile "${WORK}/ext" -out "${dir}/tls.crt" 2>/dev/null
  cp "${WORK}/ca.crt" "${dir}/"
}

# Every tenant pins the same chart (upstream.sh moves them together).
CHART=$(jq -r .chartVersion gitops/tenants/*/config.json | sort -u)
[ "$(wc -l <<<"${CHART}")" = 1 ] || { echo "tenants pin different charts: ${CHART}"; exit 1; }
tf_vars=(-input=false -var kubeconfig=/work/kubeconfig -var moto_ca_bundle=/work/ca.crt -var "chart_version=${CHART}")

# One throwaway CA signs both stand-ins' certificates, so every call in the
# test, AWS and GitLab alike, is TLS-verified, as it would be for real.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=terraform-e2e-ca \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign \
  -keyout "${WORK}/ca.key" -out "${WORK}/ca.crt" 2>/dev/null

log "moto ${MOTO_VERSION}, Terraform ${TERRAFORM_VERSION}, gitlab-runner chart ${CHART}"
docker rm -f "${MOTO}" "${STUB}" >/dev/null 2>&1 || true
# Over HTTPS: the cache bucket's policy refuses anything else. The second
# name is the host S3 Control calls, which prefixes the account ID.
issue "${WORK}/moto" moto "${ACCOUNT}.moto" localhost
docker run -d --name "${MOTO}" --network kind \
  --network-alias moto --network-alias "${ACCOUNT}.moto" -v "${WORK}/moto:/tls:ro" \
  "motoserver/moto:${MOTO_VERSION}" -s -c /tls/tls.crt -k /tls/tls.key >/dev/null
wait_for 60 moto moto_up

log "GitLab stand-in at https://${GITLAB_HOST}"
issue "${WORK}/stub" "${GITLAB_HOST}"
cp .github/scripts/gitlab-stub.py "${WORK}/stub/"
# The moto image, already pinned, ships the Python the stand-in needs.
docker run -d --name "${STUB}" --network kind -v "${WORK}/stub:/stub:ro" --entrypoint python3 \
  "motoserver/moto:${MOTO_VERSION}" -u /stub/gitlab-stub.py /stub/tls.crt /stub/tls.key >/dev/null
IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${STUB}")
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' |
  awk -v ip="${IP}" -v host="${GITLAB_HOST}" \
    '/^ *forward / && !done { print "    hosts {\n        " ip " " host "\n        fallthrough\n    }"; done=1 } { print }' \
  > "${WORK}/Corefile"
kubectl -n kube-system patch configmap coredns --type merge \
  -p "$(jq -n --rawfile c "${WORK}/Corefile" '{data: {Corefile: $c}}')" >/dev/null
kubectl -n kube-system rollout restart deploy/coredns >/dev/null
kubectl -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null
echo "${GITLAB_HOST} is ${IP} in the cluster"

kind get kubeconfig --internal --name "${CLUSTER}" > "${WORK}/kubeconfig"
mkdir -p "${WORK}/src"
tar -cf - --exclude=.terraform --exclude='*.tfstate*' terraform | tar -xf - -C "${WORK}/src"

# Stand-in for the secret store. The module creates each tenant namespace
# and then waits for its runner, so the runner token and the CA (never in
# Terraform) can only be synced into the namespace once it exists, the way a
# ClusterExternalSecret selecting platform.ci/tenant namespaces would. Each
# tenant gets its own token, so the stand-in's log shows which runner called.
sync_secrets() {
  while :; do
    for ns in $(kubectl get ns -l platform.ci/tenant -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      kubectl -n "${ns}" get secret gitlab-runner-token >/dev/null 2>&1 && continue
      kubectl -n "${ns}" create secret generic gitlab-ca --from-file="${GITLAB_HOST}.crt=${WORK}/ca.crt" >/dev/null 2>&1 || continue
      if kubectl -n "${ns}" create secret generic gitlab-runner-token \
        --from-literal=runner-token="glrt-e2e-${ns}" --from-literal=runner-registration-token= >/dev/null 2>&1; then
        echo "secret store: synced gitlab-ca and gitlab-runner-token into ${ns}"
      fi
    done
    sleep 2
  done
}
sync_secrets &
SYNC_PID=$!

log "terraform apply"
tf init -input=false -backend-config=path=/work/terraform.tfstate >/dev/null
tf apply -auto-approve "${tf_vars[@]}" -no-color > "${WORK}/apply.log" 2>&1 || { tail -40 "${WORK}/apply.log"; exit 1; }
grep -E '^Apply complete' "${WORK}/apply.log"
tf output -json > "${WORK}/outputs.json"
BUCKET=$(jq -r .cache_bucket.value "${WORK}/outputs.json")
TENANTS=$(jq -r '.tenant_namespaces.value | keys[]' "${WORK}/outputs.json")

# The provider sends the cache bucket's tags inside CreateBucket, which AWS
# applies and moto ignores. Give moto the tags Terraform planned for that one
# bucket, so the second plan compares against what AWS would hold. Nothing
# else is touched.
tf plan -out=/work/tags.tfplan "${tf_vars[@]}" >/dev/null
aws_check tag "${BUCKET}" "${ACCOUNT}" "$(tf show -json /work/tags.tfplan |
  jq -c '[.resource_changes[] | select(.address == "module.runner_fleet.aws_s3_bucket.cache")
          | .change.after.tags_all | to_entries[] | {Key: .key, Value: .value}]')"

log "a second plan finds nothing to change"
rc=0
tf plan -detailed-exitcode "${tf_vars[@]}" -no-color > "${WORK}/plan.log" 2>&1 || rc=$?
if [ "${rc}" != 0 ]; then
  grep -E '^ *(#|[-+~] )' "${WORK}/plan.log" || tail -40 "${WORK}/plan.log"
  echo "plan after apply exited ${rc}"; exit 1
fi
echo "no changes"

log "AWS, read back from moto"
# shellcheck disable=SC2086 # one argument per tenant
aws_check applied "${BUCKET}" "$(jq -r .oidc_provider_arn.value "${WORK}/outputs.json")" ${TENANTS}

log "Kubernetes, read back from kind"
for t in ${TENANTS}; do
  ns=$(jq -r --arg t "${t}" '.tenant_namespaces.value[$t]' "${WORK}/outputs.json")
  role=$(jq -r --arg t "${t}" '.runner_role_arns.value[$t]' "${WORK}/outputs.json")
  test "$(kubectl get ns "${ns}" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" = baseline
  test "$(kubectl get ns "${ns}" -o jsonpath='{.metadata.labels.platform\.ci/tenant}')" = "${t}"
  kubectl -n "${ns}" get resourcequota/ci-quota limitrange/ci-defaults networkpolicy/ci-isolation >/dev/null
  kubectl -n "${ns}" rollout status deploy/gitlab-runner --timeout=60s >/dev/null
  test "$(kubectl -n "${ns}" get sa gitlab-runner -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')" = "${role}"
  kubectl -n "${ns}" get configmap gitlab-runner -o jsonpath='{.data.config\.template\.toml}' |
    grep -F "BucketName = \"${BUCKET}\"" >/dev/null
  # Started means verified: the runner exits if GitLab rejects its token or
  # its certificate. Polling for jobs means it stayed up.
  polled() { docker logs "${STUB}" 2>/dev/null | grep -F "POST /api/v4/jobs/request token=glrt-e2e-${ns}" >/dev/null; }
  wait_for 120 "${t}'s runner to poll for jobs" polled
  docker logs "${STUB}" 2>/dev/null | grep -F "POST /api/v4/runners/verify token=glrt-e2e-${ns}" >/dev/null
  echo "${t}: ${ns} is labeled baseline with its quota, limits and network policy; its runner is ready, verified over the private CA and polls for jobs, as ${role}, caching to ${BUCKET}"
done

# A cache object under a tenant's prefix, as a job would leave one: destroy
# must empty the bucket (force_destroy) rather than fail on it.
aws_check seed "${BUCKET}" "$(head -1 <<<"${TENANTS}")"

kill "${SYNC_PID}"; SYNC_PID=

log "terraform destroy"
tf destroy -auto-approve "${tf_vars[@]}" -no-color > "${WORK}/destroy.log" 2>&1 || { tail -40 "${WORK}/destroy.log"; exit 1; }
grep -E '^Destroy complete' "${WORK}/destroy.log"
test -z "$(tf state list)"
left=$(kubectl get ns -l platform.ci/tenant -o name)
[ -z "${left}" ] || { echo "namespaces left after destroy: ${left}"; exit 1; }
echo "ok: no tenant namespaces left"
aws_check destroyed

log "passed"
