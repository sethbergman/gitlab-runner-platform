# Service level objectives

The platform's users are engineers waiting on pipelines, so the SLOs measure waiting, and failures the platform caused. Build failures caused by the code under test are out of scope.

| SLI | Objective (28 days) | Source |
|---|---|---|
| **Job start latency**: time from a job being picked up to its pod running | 95% of jobs start within 30 s during business hours | GitLab Runner job metrics, or job-pod timestamps from kube-state-metrics |
| **Platform-caused job failures**: jobs failing with `runner_system_failure` or `stuck_or_timeout_failure` | Under 0.5% of jobs | The `failure_reason` field of the GitLab jobs API |
| **Autoscaler freshness**: minutes with a successful reconcile | 99.5% | `warmpool_last_success_timestamp_seconds` |

## Example queries

Autoscaler freshness, as a ratio of good minutes:

```promql
avg_over_time(
  ((time() - warmpool_last_success_timestamp_seconds) < bool 60)[28d:1m]
)
```

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
