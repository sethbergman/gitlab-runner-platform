# Security

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: [report a vulnerability](https://github.com/sethbergman/gitlab-runner-platform/security/advisories/new), or **Security → Report a vulnerability** on this repository. It opens a private advisory that only the maintainer can see. Please do not open a public issue for anything exploitable.

Expect an acknowledgement within a week. Fixes ship as a new `v*` tag of the autoscaler image or a change to the Terraform module and manifests, and the advisory is published once a fix is available.

## Supported versions

Only the latest `v*` tag of `ghcr.io/sethbergman/warmpool-autoscaler` and the `main` branch of the Terraform module and manifests are supported. Earlier tags stay on GHCR for reproducibility but are not patched.

## What is in scope

- The `warmpool-autoscaler` image and its source under `autoscaler/`
- The Terraform module under `terraform/modules/runner-fleet` and its guardrails (tenant isolation, IAM scoping, network policy)
- The manifests under `deploy/` and `gitops/`

The GitLab Runner chart, Argo CD and the cloud providers are upstream projects; report issues in them upstream.

## How releases are protected

- `main` accepts changes only through pull requests with every CI job green, with linear history and no force pushes.
- Every `v*` tag publishes a multi-architecture image with a BuildKit SBOM and provenance on the index and a Sigstore-signed build-provenance attestation. Verify before deploying:

  ```bash
  gh attestation verify oci://ghcr.io/sethbergman/warmpool-autoscaler:<tag> --owner sethbergman
  ```

- Dependabot and a weekly upstream check keep actions, Go, the base images, the warm pool's pause image, providers, CI tools and the runner chart current; `govulncheck`, Checkov and CodeQL run on every push, and OpenSSF Scorecard on `main` and weekly, with findings in the Security tab.
