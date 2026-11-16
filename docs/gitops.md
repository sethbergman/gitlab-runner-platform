# GitOps with Argo CD

Terraform and Argo CD each own the part they are best at:

| Owner | What | Why |
|---|---|---|
| **Terraform** | S3 cache, IAM roles, tenant namespaces and their guardrails (Pod Security labels, quota, limit range, network policy) | These need AWS identifiers or are security boundaries. They change rarely and deserve a reviewed `plan`. |
| **Argo CD** | Warm pool, autoscaler, and each tenant's runner release | In-cluster workloads that change often. Git is the record, drift is reverted, and rollback is `git revert`. |

The `ci-tenants` Argo CD project blacklists ResourceQuota, LimitRange and NetworkPolicy, so a runner release can never change the guardrails Terraform set, even by mistake. See [ADR 0004](decisions/0004-gitops-handoff.md).

## Layout

```text
gitops/
  bootstrap/root.yaml          # the one object applied by hand (app-of-apps)
  platform/
    appproject.yaml            # ci-system and ci-tenants projects
    warmpool-autoscaler.yaml   # deploy/autoscaler, replicas ignored
    runner-tenants.yaml        # ApplicationSet: one runner per tenant folder
  tenants/<tenant>/
    config.json                # tenant name and pinned chart version
    values.yaml                # GENERATED from Terraform; do not hand-edit
```

## Turning it on

1. Install Argo CD in the cluster (Helm chart or the EKS Capability for Argo CD).
2. In `terraform/examples/eks`, set `use_gitops = true` and apply. Terraform keeps creating AWS resources and tenant guardrails, and stops installing runners itself.
3. Generate the tenant values from Terraform and commit them:
   ```bash
   make gitops-values
   git add gitops/tenants && git commit -m "Update runner values" && git push
   ```
4. Bootstrap once: `kubectl apply -n argocd -f gitops/bootstrap/root.yaml`.

From then on, every change is a pull request. Argo CD applies it after merge.

## Why values are generated, not hand-written

A tenant's runner values contain its IAM role ARN and cache bucket, which come from Terraform. Writing them by hand would let the two drift apart, so the values are rendered from the same template Terraform uses in Helm mode (`runner_helm_values` output) and committed by `make gitops-values`. A reviewer sees the exact rendered diff in the pull request.

## The replicas gotcha

The warm-pool Deployment says `replicas: 0` in Git, but `warmpool-autoscaler` changes it all day. Left alone, Argo CD would see each resize as drift, and self-heal would reset the pool, fighting the autoscaler every few seconds. The autoscaler Application therefore ignores `/spec/replicas` on that one Deployment, and `RespectIgnoreDifferences=true` keeps a sync from resetting it either.

CI proves both halves on every push (`gitops-e2e` job, on a kind cluster):

- scaling the warm pool by hand leaves the app `Synced` and the new size in place;
- changing a field that Git does own is reverted by self-heal.

## Adding a tenant

1. Add it to `tenants` in Terraform and apply (namespace, guardrails, IAM role).
2. Store its runner token in the secret store, synced to `gitlab-runner-token` in `ci-<tenant>`.
3. `make gitops-values`, commit, open a pull request. The ApplicationSet creates `runner-<tenant>` after merge.
