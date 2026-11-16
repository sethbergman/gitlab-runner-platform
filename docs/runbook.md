# Runbook

## Autoscaler stale

Alerts: `WarmPoolAutoscalerStale`, `WarmPoolAutoscalerAbsent`.

Impact: the warm pool holds its last size. Jobs still run; new waves may wait on node boots.

```bash
kubectl -n gitlab-runner-system get pods -l app.kubernetes.io/name=warmpool-autoscaler
kubectl -n gitlab-runner-system logs deploy/warmpool-autoscaler --since=30m | grep -E '"level":"(WARN|ERROR)"'
kubectl -n gitlab-runner-system port-forward svc/warmpool-autoscaler 8080 &
curl -s localhost:8080/metrics | grep warmpool_errors_total
```

| `stage` with errors | Likely cause | Fix |
|---|---|---|
| `queue`, `401` | `read_api` token expired or revoked | Rotate it in the secret store, then `kubectl -n gitlab-runner-system rollout restart deploy/warmpool-autoscaler` (the token is read at startup). |
| `queue`, `404` | A project in `GITLAB_PROJECTS` was renamed or deleted | Update the ConfigMap. |
| `queue`, timeouts | GitLab degraded or egress blocked | Check GitLab status; check egress from `gitlab-runner-system`. |
| `scale_get` / `scale_set`, `403` | RBAC changed, or the warm-pool Deployment was renamed | Re-apply `deploy/autoscaler`. |

## Pool pinned at max

Alert: `WarmPoolPinnedAtMax`.

1. Check whether demand is real: one pipeline fanning out a large matrix is a team conversation, not a capacity change.
2. If demand grew, raise `MAX_REPLICAS` and the CI node group's maximum together. Raising only one does nothing.
3. Check tenant quotas: `kubectl describe resourcequota -n ci-<tenant>`.

## Runner at concurrency limit

Alert: `GitLabRunnerAtConcurrencyLimit`.

Jobs queue in GitLab even though nodes are free. Raise the tenant's `concurrent` in Terraform, and its `quota_*` values if pods would then exceed the quota. Apply; the Helm release upgrades atomically and rolls back on failure.

## Runner errors

Alert: `GitLabRunnerErrors`.

```bash
kubectl -n ci-<tenant> logs deploy/gitlab-runner --since=30m | grep '"level":"error"'
```

Common causes: the runner token was rotated in GitLab but not in the Secret; job pods rejected by the ResourceQuota (`exceeded quota` events in the namespace); job pods rejected by Pod Security admission (a job asked for `privileged`).

## Rotating a runner token

1. Create a new token for the runner in GitLab (the old one keeps working until revoked).
2. Update it in the secret store and let it sync to `gitlab-runner-token` in `ci-<tenant>`.
3. `kubectl -n ci-<tenant> rollout restart deploy/gitlab-runner`.
4. Confirm the runner shows as online in GitLab, then revoke the old token.

## Upgrading the runner chart

The chart version is pinned in one place: `chart_version` in `terraform.tfvars`. In GitOps mode, `make gitops-values` copies it into every `gitops/tenants/<tenant>/config.json`, and CI fails a pull request whose `config.json` disagrees with what the example renders, so the two cannot drift.

[`upstream.yml`](../.github/workflows/upstream.yml) opens a `deps/gitlab-runner-chart` pull request every Monday when a newer chart exists, with every tenant's `config.json` and `terraform.tfvars.example` already bumped and CI run on it: each tenant rendered with the new chart through kubeconform, and one synced release per tenant on a kind cluster. CI cannot run jobs, so the checks that matter are yours:

1. Read the chart's release notes and confirm the bundled runner matches your GitLab version; runner and GitLab move together.
2. Set the same version in your `terraform.tfvars`. Otherwise the next `make gitops-values` writes the old version back.
3. Roll it out:
   - **Terraform-installed runners.** Apply the new version to a canary first: a second `runner_fleet` module call holding one tenant, or a canary cluster. Releases are `atomic`, so a failed upgrade rolls back on its own.
   - **Argo CD-installed runners.** Merge the pull request; Argo CD upgrades every tenant on its next sync. There is no per-tenant canary on this path, since every `config.json` carries the same generated version, so use a canary cluster bootstrapped from the branch if you need one. Argo CD applies rendered manifests rather than running `helm upgrade`, so nothing rolls back on its own: a bad upgrade leaves `runner-<tenant>` Degraded, and reverting the merge is the rollback.
4. Watch the upgraded tenant's job success rate for a day, then roll to the rest.

## Releasing the autoscaler

A release is a tag on `main`:

```bash
git tag -a v0.2.0 -m "v0.2.0" && git push origin v0.2.0
```

CI builds and pushes `ghcr.io/sethbergman/warmpool-autoscaler:v0.2.0` for linux/amd64 and linux/arm64 with a BuildKit SBOM and provenance on the image index, signs a build-provenance attestation for it through Sigstore, and, once every other job is green, creates the GitHub Release with the image digest and the verify commands in its notes. A tag with a hyphen (`v0.2.0-rc.1`) becomes a prerelease.

Then roll it out: verify the attestation, pin the digest in `deploy/autoscaler/deployment.yaml` and open a pull request. The GitOps e2e proves the pinned image boots before the pull request merges.

```bash
gh attestation verify oci://ghcr.io/sethbergman/warmpool-autoscaler:v0.2.0 --owner sethbergman
```
