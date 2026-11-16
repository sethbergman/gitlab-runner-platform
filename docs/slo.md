# Service level objectives

The platform's users are engineers waiting on pipelines, so the SLOs measure waiting, and failures the platform caused. Build failures caused by the code under test are out of scope.

| SLI | Objective (28 days) | Source |
|---|---|---|
| **Job start latency**: time from a job being picked up to its pod running | 95% of jobs start within 30 s during business hours | GitLab Runner job metrics, or job-pod timestamps from kube-state-metrics |
| **Platform-caused job failures**: jobs failing with `runner_system_failure` or `stuck_or_timeout_failure` | Under 0.5% of jobs | The `failure_reason` field of the GitLab jobs API |
| **Autoscaler freshness**: minutes with a successful reconcile | 99.5% | `warmpool_last_success_timestamp_seconds` |

## Example queries

Autoscaler freshness, as a ratio of good minutes. [`prometheus-rules.yaml`](../observability/prometheus-rules.yaml) records `warmpool:fresh_minute:bool` every minute (1 when the last successful reconcile is under 60 s old), so the SLI is its 28-day average:

```promql
avg_over_time(warmpool:fresh_minute:bool[28d])
```

`WarmPoolFreshnessBudgetBurn` fires when both the last 6 hours and the last 30 minutes burn the 0.5% budget at six times the sustainable rate. That catches intermittent failures too short for `WarmPoolAutoscalerStale`, which needs ten stale minutes in a row. Every alert in the rule file has a unit test in [`prometheus-rules.test.yaml`](../observability/prometheus-rules.test.yaml), run by `make rules` and CI.

How long job pods in one tenant waited to be scheduled, per pod, from kube-state-metrics:

```promql
kube_pod_status_scheduled_time{namespace="ci-payments"}
  - on (namespace, pod) kube_pod_created{namespace="ci-payments"}
```

Runner metric names and labels vary across GitLab Runner versions. Before you wire the job-start SLI into alerting, check `/metrics` on a runner manager and pick a histogram whose buckets include your 30 s threshold.

## Error budget policy

- **Budget healthy:** ship platform changes freely, including chart upgrades and node AMI rollouts.
- **Budget under 25%:** chart and AMI upgrades go to one tenant first and soak for a day.
- **Budget spent:** freeze platform changes except fixes, and review warm-pool settings and node-group limits first, since capacity is the usual cause.
