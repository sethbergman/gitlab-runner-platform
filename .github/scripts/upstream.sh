#!/usr/bin/env bash
# Opens, or refreshes, one pull request per upstream pin that is behind its
# latest release; CI runs on it as on any pull request. Dependabot sees none
# of these:
#
#   - the tools CI installs from GitHub releases, each pinned in a file under
#     .github/versions/ (actionlint, argocd for the e2e job, kubeconform,
#     moto for the Terraform e2e, prometheus for promtool, terraform) rather
#     than in a workflow, which a workflow token may not edit;
#   - the gitlab-runner chart every tenant pins (gitops/tenants/*/config.json
#     and terraform/examples/eks/terraform.tfvars.example);
#   - the GitLab CE image the gitlab-e2e workflow boots (.github/versions/gitlab);
#   - the warm pool's pause image (deploy/autoscaler/warm-pool.yaml), which
#     Dependabot skips: registry.k8s.io's `latest` is pause 1.0, so it takes
#     every 3.x tag for a pre-release.
#
# Run from the repository root on a clean checkout of main, with GH_TOKEN set
# to a token whose pushes and pull requests trigger workflows: upstream.yml's
# GitHub App, or your own when run by hand. The workflow's own GITHUB_TOKEN
# does not qualify (see upstream.yml).
# DRY_RUN=1 prints what would be opened and touches nothing on GitHub.
set -euo pipefail

dry() { [ "${DRY_RUN:-0}" != 0 ]; }
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; } # newer current latest

# Commits the working-tree edits on $branch, pushes, and opens or refreshes the
# pull request, which runs CI.
propose() { # branch title body file...
  local branch=$1 title=$2 body=$3 open
  shift 3
  if dry; then
    echo "would open '${title}' on ${branch}:"
    git --no-pager diff --stat -- "$@"
    git checkout -q -- "$@"
    return
  fi
  open=$(gh pr list --head "${branch}" --state open --json title --jq '.[0].title')
  if [ "${open}" = "${title}" ]; then
    echo "already open: ${title}"
    git checkout -q -- "$@"
    return
  fi
  git checkout -q -B "${branch}"
  git commit -q -m "${title}" -- "$@"
  git push -q -f origin "${branch}"
  if [ -n "${open}" ]; then
    gh pr edit "${branch}" --title "${title}" --body "${body}"
  else
    gh pr create --head "${branch}" --base main --title "${title}" --body "${body}"
  fi
  git checkout -q main
}

github_latest() { # owner/repo, prints the tag of the latest release
  curl -fsSL -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name
}

# Tools pinned under .github/versions/: pin file, repository, and whether the
# file holds the tag as is or without its leading v (setup-terraform and the
# actionlint, moto and terraform images take a bare version).
for spec in \
  "actionlint  rhysd/actionlint      bare" \
  "argocd      argoproj/argo-cd      tag" \
  "kubeconform yannh/kubeconform     tag" \
  "moto        getmoto/moto          bare" \
  "prometheus  prometheus/prometheus tag" \
  "terraform   hashicorp/terraform   bare"
do
  read -r name repo form <<<"${spec}"
  current=$(cat ".github/versions/${name}")
  tag=$(github_latest "${repo}")
  latest=${tag}
  [ "${form}" = bare ] && latest=${tag#v}
  echo "${name}: pinned ${current}, latest ${latest}"
  newer "${current}" "${latest}" || continue
  echo "${latest}" > ".github/versions/${name}"
  propose "deps/${name}" "Bump ${name} to ${latest} in CI" \
    "CI pinned ${name} ${current}; ${latest} is the latest release: https://github.com/${repo}/releases/tag/${tag}

Nothing deployed changes: this only moves the version CI installs. A green run here is the evidence that the checks still pass on it.

Opened by .github/workflows/upstream.yml." ".github/versions/${name}"
done

# gitlab-runner chart, as pinned by every tenant and the Terraform example.
current=$(jq -r .chartVersion gitops/tenants/*/config.json | sort -u)
if [ "$(wc -l <<<"${current}")" != 1 ]; then
  echo "tenants pin different chart versions:"; echo "${current}"; exit 1
fi
helm repo add --force-update gitlab https://charts.gitlab.io >/dev/null
latest=$(helm search repo gitlab/gitlab-runner --output json | jq -r '.[0].version')
echo "gitlab-runner chart: pinned ${current}, latest ${latest}"
if newer "${current}" "${latest}"; then
  for f in gitops/tenants/*/config.json; do
    jq --arg v "${latest}" '.chartVersion = $v' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
  done
  sed -i "s/^\(chart_version *= *\)\"[^\"]*\"/\1\"${latest}\"/" terraform/examples/eks/terraform.tfvars.example
  propose deps/gitlab-runner-chart "Bump the gitlab-runner chart to ${latest}" \
    "Every tenant pinned gitlab-runner chart ${current}; ${latest} is the latest release. Changelog: https://gitlab.com/gitlab-org/charts/gitlab-runner/-/blob/main/CHANGELOG.md

Changes gitops/tenants/*/config.json and the Terraform example's chart_version together, which the Terraform test requires. CI renders every tenant with the new chart and syncs them through Argo CD on kind.

Opened by .github/workflows/upstream.yml." gitops/tenants/*/config.json terraform/examples/eks/terraform.tfvars.example
fi

# GitLab CE for the gitlab-e2e workflow: the newest x.y.z-ce.0 on Docker Hub.
# That workflow is what the bump must pass; it runs on pull requests that
# change .github/versions/gitlab.
current=$(cat .github/versions/gitlab)
latest=$(curl -fsSL 'https://hub.docker.com/v2/repositories/gitlab/gitlab-ce/tags?page_size=100&ordering=last_updated' |
  jq -r '.results[].name' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-ce\.0$' | sort -V | tail -1)
echo "gitlab-ce: pinned ${current}, latest ${latest}"
if newer "${current}" "${latest}"; then
  echo "${latest}" > .github/versions/gitlab
  propose deps/gitlab "Bump GitLab CE to ${latest} in the GitLab e2e" \
    "The GitLab e2e booted GitLab CE ${current}; ${latest} is the newest release on Docker Hub: https://hub.docker.com/r/gitlab/gitlab-ce/tags

Nothing deployed changes. The gitlab-e2e run on this pull request is the evidence that the autoscaler and the tenant runners still work against it.

Opened by .github/workflows/upstream.yml." .github/versions/gitlab
fi

# The warm pool's pause image, pinned by tag and by the digest of its
# multi-architecture index: the newest numeric tag on registry.k8s.io.
pin=$(grep -oE 'registry\.k8s\.io/pause:[^@ ]+@sha256:[0-9a-f]{64}' deploy/autoscaler/warm-pool.yaml)
current=${pin#*:}
current=${current%@*}
latest=$(curl -fsSL https://registry.k8s.io/v2/pause/tags/list |
  jq -r '.tags[]' | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -1)
echo "pause: pinned ${current}, latest ${latest}"
if newer "${current}" "${latest}"; then
  digest=$(curl -fsSIL \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://registry.k8s.io/v2/pause/manifests/${latest}" |
    tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { d = $2 } END { print d }')
  if ! [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "no index digest for pause:${latest}"; exit 1
  fi
  sed -i "s#${pin}#registry.k8s.io/pause:${latest}@${digest}#" deploy/autoscaler/warm-pool.yaml
  propose deps/pause "Bump the warm pool's pause image to ${latest}" \
    "The warm pool's placeholders ran registry.k8s.io/pause:${current}; ${latest} is the newest tag on registry.k8s.io, pinned here to the digest of its multi-architecture index, ${digest}.

The GitOps e2e in this pull request's CI runs three placeholders from it and checks each runs this digest.

Opened by .github/workflows/upstream.yml." deploy/autoscaler/warm-pool.yaml
fi
