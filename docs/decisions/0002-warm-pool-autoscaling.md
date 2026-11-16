# 0002: Queue-driven warm pool instead of fixed over-provisioning

- Status: accepted
- Date: 2026-11-15

## Context

With the Kubernetes executor, a burst of jobs waits for the cluster autoscaler to add nodes. Options considered:

1. **Fixed node-group minimum.** Simple, but pays for idle nodes around the clock and cannot follow demand.
2. **Scale the node group from the queue directly.** Duplicates the cluster autoscaler and fights it over desired capacity.
3. **Placeholder pods sized from the queue.** Low-priority pods hold capacity; real jobs preempt them; the cluster autoscaler stays the only thing that manages nodes.
4. **KEDA with a metrics scaler on a placeholder Deployment.** Viable, but adds an operator, and the business-hours schedule and GitLab tag matching would still need custom code.

## Decision

Option 3, with a small dedicated controller (`warmpool-autoscaler`). It has no third-party dependencies and RBAC to patch one Deployment's scale.

## Consequences

- Jobs start on warm nodes during bursts; the pool falls to zero off-hours.
- The controller is off the critical path: if it fails, the pool holds its size and jobs fall back to normal cold starts.
- Placeholders must be sized like real job pods, and kept in step when job requests change.
- If the team later standardizes on KEDA, the policy package can be reused behind an external scaler.
