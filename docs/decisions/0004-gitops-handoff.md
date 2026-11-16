# 0004: Terraform owns AWS and guardrails; Argo CD owns in-cluster workloads

- Status: accepted
- Date: 2026-11-15

## Context

Everything in this platform could be applied by Terraform, but in-cluster workloads change far more often than AWS resources, and `terraform apply` has no drift correction between runs. Moving everything into Argo CD would instead put IAM roles and buckets behind controllers (ACK or Crossplane) the platform does not otherwise need.

## Decision

Split ownership along the line where identifiers and trust change:

- Terraform: S3 cache, IAM roles, tenant namespaces and their guardrails.
- Argo CD: warm pool, autoscaler, and per-tenant runner releases (app-of-apps plus an ApplicationSet).

Runner values that depend on Terraform outputs are rendered by Terraform and committed to Git (`make gitops-values`), not hand-written. The module keeps a Helm mode (`manage_runner_releases = true`) for teams without Argo CD.

## Consequences

- Workload changes are pull requests with continuous drift correction; AWS and guardrail changes keep a reviewed `plan`.
- The `ci-tenants` project blacklists ResourceQuota, LimitRange and NetworkPolicy, so the boundary is enforced, not just documented.
- One extra step when Terraform inputs change: regenerate and commit the tenant values.
- The warm pool's replica count is runtime state owned by the autoscaler, so Argo CD must ignore it; CI tests this explicitly.
