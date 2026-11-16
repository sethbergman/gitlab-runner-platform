# Autoscaling design

## Signal

The autoscaler counts **pending jobs that this fleet could run**, using `GET /api/v4/projects/:id/jobs?scope[]=pending` for each configured project, and GitLab's own matching rule: a runner takes a job only if every tag on the job is also on the runner, and takes untagged jobs only when `run_untagged` is enabled. Counting jobs the fleet cannot run would buy capacity nobody uses.

The token needs only `read_api`.

## Policy

```
target = clamp(ceil(pending / jobs_per_replica) + headroom_if_business_hours,
               floor_for_this_time, max)
```

| Setting | Default | Why |
|---|---|---|
| `JOBS_PER_REPLICA` | 1 | One placeholder is sized like one job pod (build + helper requests). |
| `HEADROOM` | 2 | The first jobs of a new wave never wait, even from an empty queue. Business hours only. |
| `MIN_BUSINESS` / `MIN_OFF_HOURS` | 2 / 0 | A floor while people are working; nothing overnight. |
| `MAX_REPLICAS` | 40 | A hard ceiling on spend. Alerted on when pinned (see runbook). |
| `BUSINESS_HOURS` | `Mon-Fri 07:00-19:00` | Evaluated in `TZ_NAME`. Also accepts `always` and `never`. |

## Stabilization

Scale-up is immediate. Scale-down uses the same rule as the Kubernetes HorizontalPodAutoscaler: the applied size is the **highest** recommendation seen in the last `SCALE_DOWN_STABILIZATION` (10 minutes). Pipelines arrive in waves (a merge triggers several, a release fans out), and releasing nodes between two waves only to boot them again costs more than holding them for a few minutes.

## Failure behavior

| Failure | Behavior |
|---|---|
| GitLab API unreachable, 4xx or 5xx | **Fail static**: the pool keeps its current size. `warmpool_errors_total{stage="queue"}` counts it. |
| Kubernetes API denies or times out | Nothing changes; `stage="scale_get"` or `"scale_set"` is counted. |
| Autoscaler pod down | The pool keeps its last size; jobs still run, just without new warm capacity. `WarmPoolAutoscalerStale` and `WarmPoolAutoscalerAbsent` fire. |

The autoscaler is never on the critical path of a job. At worst, jobs fall back to normal cluster-autoscaler cold starts.

## Sizing a placeholder

A placeholder should request what one typical job pod requests: the build container's `job_cpu_request` and `job_memory_request` plus the helper's requests. With the module defaults that is `500m + 100m` CPU and `1Gi + 128Mi` memory, which is what `deploy/autoscaler/warm-pool.yaml` uses. If your tenants use very different job sizes, run one warm pool and autoscaler per node group.

## Tuning in practice

Start with the defaults, watch the "Queue vs. warm pool" panel for a week, then adjust:

- Jobs still waiting on nodes during the day: raise `HEADROOM` or `MIN_BUSINESS`.
- Pool frequently pinned at max: raise `MAX_REPLICAS` together with the node group's max size.
- Too much idle capacity after waves: shorten `SCALE_DOWN_STABILIZATION`.
