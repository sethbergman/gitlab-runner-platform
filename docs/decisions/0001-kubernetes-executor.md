# 0001: Use the Kubernetes executor on EKS

- Status: accepted
- Date: 2026-11-15

## Context

Runners can execute jobs on long-lived VMs (shell or Docker executor), on autoscaled VMs (docker-autoscaler / fleeting), or as pods (Kubernetes executor). The platform must serve many teams with isolation between them, scale with bursty demand, and reuse the organization's existing Kubernetes tooling for security, cost and observability.

## Decision

Use the Kubernetes executor, one runner manager per tenant namespace, on a dedicated, tainted CI node group.

## Consequences

- Every job is a fresh pod: no state leaks between jobs, and per-job requests make cost attribution possible.
- Isolation reuses Kubernetes primitives (namespaces, quotas, network policy, Pod Security) instead of bespoke VM hardening.
- Docker-in-Docker would need privileged pods, which `baseline` Pod Security forbids. Image builds use rootless BuildKit or Kaniko instead. Teams that truly need privileged builds get a separate, isolated runner outside this platform.
- Cold node starts become the dominant source of queue time, which ADR 0002 addresses.
