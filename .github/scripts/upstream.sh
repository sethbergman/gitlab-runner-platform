#!/usr/bin/env bash
# Opens, or refreshes, one pull request per upstream pin that is behind its
# latest release, then runs CI on it. Dependabot sees none of these:
#
#   - the tools CI installs from GitHub releases, each pinned in a file under
#     .github/versions/ (actionlint, argocd for the e2e job, kubeconform,
#     moto for the Terraform e2e, prometheus for promtool, terraform) rather
#     than in a workflow, which a workflow token may not edit;
#   - the gitlab-runner chart every tenant pins (gitops/tenants/*/config.json
#     and terraform/examples/eks/terraform.tfvars.example);
#   - the GitLab CE image the gitlab-e2e workflow boots (.github/versions/gitlab).
#
# Run from the repository root on a clean checkout of main, with GH_TOKEN set.
# DRY_RUN=1 prints what would be opened and touches nothing on GitHub.
set -euo pipefail

dry() { [ "${DRY_RUN:-0}" != 0 ]; }
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; } # newer current latest

# Commits the working-tree edits on $branch, pushes, and opens or refreshes the
# pull request, then dispatches CI on the branch (a push from GITHUB_TOKEN
# does not trigger it by itself).
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
  gh workflow run ci.yml --ref "${branch}"
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
# That workflow is what the bump must pass, so it is dispatched too.
current=$(cat .github/versions/gitlab)
latest=$(curl -fsSL 'https://hub.docker.com/v2/repositories/gitlab/gitlab-ce/tags?page_size=100&ordering=last_updated' |
  jq -r '.results[].name' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-ce\.0$' | sort -V | tail -1)
echo "gitlab-ce: pinned ${current}, latest ${latest}"
if newer "${current}" "${latest}"; then
  echo "${latest}" > .github/versions/gitlab
  propose deps/gitlab "Bump GitLab CE to ${latest} in the GitLab e2e" \
    "The GitLab e2e booted GitLab CE ${current}; ${latest} is the newest release on Docker Hub: https://hub.docker.com/r/gitlab/gitlab-ce/tags

Nothing deployed changes. The gitlab-e2e run dispatched on this branch is the evidence that the autoscaler and the tenant runners still work against it.

Opened by .github/workflows/upstream.yml." .github/versions/gitlab
  dry || gh workflow run gitlab-e2e.yml --ref deps/gitlab
fi
