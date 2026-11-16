# Architecture

## Components

| Component | Runs in | Owns |
|---|---|---|
| Runner manager (one per tenant) | `ci-<tenant>` | Polls GitLab for jobs, creates job pods in its own namespace, signs cache URLs |
| Job pods | `ci-<tenant>`, on CI nodes | The build, a helper container, and any `services:` the job declares |
| `runner-warm-pool` | `gitlab-runner-system`, on CI nodes | Placeholder pods that hold node capacity |
| `warmpool-autoscaler` | `gitlab-runner-system` | Sizing the warm pool from the GitLab queue |
| S3 cache | AWS | Build caches, partitioned by tenant prefix |
| Cluster autoscaler or Karpenter | cluster-wide | Adding and removing CI nodes |

## Life of a job

1. A pipeline starts and GitLab marks its jobs `pending`.
2. `warmpool-autoscaler` sees the pending jobs that match this fleet's tags and scales the warm pool up within one interval (15 s by default).
3. A runner manager picks up the job and creates a job pod with default priority (0).
4. If no node has room, the scheduler preempts a placeholder (priority -10), so the job pod starts on a node that is already running and has its images cached.
5. The evicted placeholder becomes pending, and the cluster autoscaler adds a node for it in the background. The next job finds capacity waiting.
6. When the queue drains, the autoscaler holds the pool for the stabilization window (10 minutes), then shrinks it, and idle nodes are removed.

## Tenancy boundaries

Each tenant is a separate failure and security domain:

- **Namespace** with Pod Security admission `baseline` enforced.
- **ResourceQuota** caps a tenant's total CPU, memory and pods, so one team's runaway matrix build cannot starve the others.
- **LimitRange** gives defaults to containers that declare none (common for job `services:`), so the quota can still admit them.
- **NetworkPolicy** denies ingress except metrics scrapes, and blocks egress to `169.254.169.254` so builds cannot borrow the node's IAM role.
- **IAM role (IRSA)** trusted only by that namespace's runner service account, allowed only its own cache prefix.
- **Runner manager** of its own, so a tenant's `concurrent` setting, token rotation or chart upgrade affects only that tenant.

## Why the warm pool, rather than over-provisioning nodes

Over-provisioning a node group with a fixed minimum keeps capacity around but cannot follow demand, and it costs the same at 3 a.m. as at 10 a.m. Scaling the node group directly from the queue would duplicate the cluster autoscaler's job and fight it. A pool of preemptible placeholders lets the cluster autoscaler keep doing what it is good at, while the queue decides how much spare capacity to ask it for. See [ADR 0002](decisions/0002-warm-pool-autoscaling.md).
