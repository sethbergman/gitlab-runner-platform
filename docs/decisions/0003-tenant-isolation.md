# 0003: Namespace-per-tenant isolation with prefix-scoped cache access

- Status: accepted
- Date: 2026-11-15

## Context

Teams share the CI fleet. Without boundaries, one team's runaway pipeline can starve others, a malicious or compromised build can read another team's caches, and any build can reach the node's IAM role through the instance metadata endpoint.

## Decision

Per tenant: a namespace with Pod Security `baseline`, a ResourceQuota and LimitRange, a NetworkPolicy that blocks `169.254.169.254`, its own runner manager, and an IRSA role that can access only `s3://<cache>/<tenant>/*`. Job pods receive no AWS credentials; the manager signs cache URLs.

## Consequences

- Blast radius of a bad pipeline is one tenant's quota.
- Cache poisoning across tenants is prevented by IAM, not convention.
- Network policy enforcement must be enabled on the cluster (VPC CNI network policy, Calico or Cilium); without it the policy objects exist but do nothing. The README lists this as a prerequisite.
- More runner managers to operate, which Terraform's `for_each` keeps uniform.
