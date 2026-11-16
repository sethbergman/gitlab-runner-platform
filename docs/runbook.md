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

1. Bump `chart_version` for one tenant first (split the tenants map, or apply to a canary cluster).
2. `terraform apply`. Releases are `atomic`, so a failed upgrade rolls back on its own.
3. Watch that tenant's job success rate for a day, then roll to the rest.
