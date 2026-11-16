# The README's security posture, as assertions on the module with every
# provider mocked (no AWS, no cluster): each tenant's IAM role can touch only
# its own cache prefix, is assumable only by its own service account, and
# each tenant namespace carries the Pod Security, quota and network policy
# guardrails. Mocked resources keep every configured attribute, so these
# asserts read exactly what Terraform would send to AWS and the cluster.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { name = "us-east-1", region = "us-east-1" }
  }
  # The provider validates policies as JSON even when mocked.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::ci-runner-cache-123456789012-us-east-1" }
  }
}

mock_provider "kubernetes" {}
mock_provider "helm" {}

variables {
  gitlab_url        = "https://gitlab.example.com"
  chart_version     = "0.94.3"
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE"
  oidc_provider_url = "https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE"
  tenants = {
    payments = { runner_token_secret = "gitlab-runner-token" }
    platform = { runner_token_secret = "gitlab-runner-token", quota_pods = 30 }
  }
}

run "each_tenant_reaches_only_its_own_cache_prefix" {
  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      toset(one([for s in data.aws_iam_policy_document.runner_cache[t].statement : s if s.sid == "ReadWriteOwnPrefix"]).resources)
      == toset(["${aws_s3_bucket.cache.arn}/${t}/*"])
    ])
    error_message = "A tenant's object permissions reach outside s3://<cache>/<tenant>/*."
  }

  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      toset(one([for s in data.aws_iam_policy_document.runner_cache[t].statement : s if s.sid == "ReadWriteOwnPrefix"]).actions)
      == toset(["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"])
    ])
    error_message = "A tenant's object permissions grant more than get, put, delete and abort."
  }

  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      toset(one([for s in data.aws_iam_policy_document.runner_cache[t].statement : s if s.sid == "ListOwnPrefix"]).resources) == toset([aws_s3_bucket.cache.arn])
      && toset(one(one([for s in data.aws_iam_policy_document.runner_cache[t].statement : s if s.sid == "ListOwnPrefix"]).condition).values) == toset(["${t}/*"])
      && one(one([for s in data.aws_iam_policy_document.runner_cache[t].statement : s if s.sid == "ListOwnPrefix"]).condition).variable == "s3:prefix"
    ])
    error_message = "A tenant can list the cache bucket beyond its own prefix."
  }

  assert {
    condition = alltrue([
      for t, _ in var.tenants : length(data.aws_iam_policy_document.runner_cache[t].statement) == 2
    ])
    error_message = "Without a KMS key the cache policy must hold exactly the list and read-write statements."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.cache.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "Without a KMS key the cache bucket must fall back to SSE-S3."
  }
}

run "a_kms_key_is_usable_only_for_the_cache" {
  variables {
    cache_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      toset(one([for s in data.aws_iam_policy_document.runner_cache[t].statement : s if s.sid == "UseCacheKey"]).resources) == toset([var.cache_kms_key_arn])
      && toset(one([for s in data.aws_iam_policy_document.runner_cache[t].statement : s if s.sid == "UseCacheKey"]).actions) == toset(["kms:Decrypt", "kms:GenerateDataKey"])
    ])
    error_message = "The KMS statement must cover only the cache key, for decrypt and data-key generation."
  }

  assert {
    condition = (
      one(one(aws_s3_bucket_server_side_encryption_configuration.cache.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
      && one(one(aws_s3_bucket_server_side_encryption_configuration.cache.rule).apply_server_side_encryption_by_default).kms_master_key_id == var.cache_kms_key_arn
      && one(aws_s3_bucket_server_side_encryption_configuration.cache.rule).bucket_key_enabled == true
    )
    error_message = "With a KMS key the cache bucket must encrypt with it and use a bucket key."
  }
}

run "the_cache_bucket_is_private_encrypted_in_transit_and_expiring" {
  assert {
    condition = (
      aws_s3_bucket_public_access_block.cache.block_public_acls
      && aws_s3_bucket_public_access_block.cache.block_public_policy
      && aws_s3_bucket_public_access_block.cache.ignore_public_acls
      && aws_s3_bucket_public_access_block.cache.restrict_public_buckets
    )
    error_message = "Every public-access block on the cache bucket must be on."
  }

  assert {
    condition = (
      data.aws_iam_policy_document.cache_bucket.statement[0].effect == "Deny"
      && toset(data.aws_iam_policy_document.cache_bucket.statement[0].actions) == toset(["s3:*"])
      && one(data.aws_iam_policy_document.cache_bucket.statement[0].condition).variable == "aws:SecureTransport"
      && toset(one(data.aws_iam_policy_document.cache_bucket.statement[0].condition).values) == toset(["false"])
    )
    error_message = "The bucket policy must deny every action over plain HTTP."
  }

  assert {
    condition     = one(one(aws_s3_bucket_lifecycle_configuration.cache.rule).expiration).days == var.cache_expiration_days
    error_message = "Cache objects must expire after cache_expiration_days."
  }
}

run "each_role_is_assumable_only_by_its_tenant_service_account" {
  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      toset(data.aws_iam_policy_document.runner_trust[t].statement[0].actions) == toset(["sts:AssumeRoleWithWebIdentity"])
      && toset(one(data.aws_iam_policy_document.runner_trust[t].statement[0].principals).identifiers) == toset([var.oidc_provider_arn])
      && one(data.aws_iam_policy_document.runner_trust[t].statement[0].principals).type == "Federated"
    ])
    error_message = "A runner role must be assumable only through the cluster's OIDC provider."
  }

  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      toset(one([for c in data.aws_iam_policy_document.runner_trust[t].statement[0].condition : c if endswith(c.variable, ":sub")]).values)
      == toset(["system:serviceaccount:ci-${t}:gitlab-runner"])
      && one([for c in data.aws_iam_policy_document.runner_trust[t].statement[0].condition : c if endswith(c.variable, ":sub")]).variable
      == "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE:sub"
    ])
    error_message = "A runner role's trust policy must name exactly its own tenant's service account."
  }

  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      toset(one([for c in data.aws_iam_policy_document.runner_trust[t].statement[0].condition : c if endswith(c.variable, ":aud")]).values)
      == toset(["sts.amazonaws.com"])
    ])
    error_message = "A runner role's trust policy must require the sts.amazonaws.com audience."
  }

  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      aws_iam_role.runner[t].name == "ci-runner-${t}" && aws_iam_role.runner[t].max_session_duration == 3600
    ])
    error_message = "Runner roles must be named per tenant with one-hour sessions."
  }
}

run "each_namespace_carries_the_tenant_guardrails" {
  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      kubernetes_namespace_v1.tenant[t].metadata[0].name == "ci-${t}"
      && kubernetes_namespace_v1.tenant[t].metadata[0].labels["pod-security.kubernetes.io/enforce"] == "baseline"
      && kubernetes_namespace_v1.tenant[t].metadata[0].labels["pod-security.kubernetes.io/warn"] == "restricted"
      && kubernetes_namespace_v1.tenant[t].metadata[0].labels["pod-security.kubernetes.io/audit"] == "restricted"
      && kubernetes_namespace_v1.tenant[t].metadata[0].labels["platform.ci/tenant"] == t
    ])
    error_message = "A tenant namespace must enforce Pod Security baseline, warn and audit on restricted, and carry its tenant label."
  }

  assert {
    condition = (
      kubernetes_resource_quota_v1.tenant["platform"].spec[0].hard["pods"] == "30"
      && kubernetes_resource_quota_v1.tenant["payments"].spec[0].hard["pods"] == "60"
      && alltrue([
        for t, _ in var.tenants :
        toset(keys(kubernetes_resource_quota_v1.tenant[t].spec[0].hard)) == toset(["requests.cpu", "requests.memory", "limits.cpu", "limits.memory", "pods"])
      ])
    )
    error_message = "Each tenant's quota must cap cpu, memory and pods with the tenant's own numbers."
  }

  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      kubernetes_limit_range_v1.tenant[t].spec[0].limit[0].type == "Container"
      && length(kubernetes_limit_range_v1.tenant[t].spec[0].limit[0].default_request) == 2
      && length(kubernetes_limit_range_v1.tenant[t].spec[0].limit[0].default) == 2
    ])
    error_message = "Each tenant namespace must default container requests and limits."
  }

  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      toset(kubernetes_network_policy_v1.tenant[t].spec[0].policy_types) == toset(["Ingress", "Egress"])
      && length(kubernetes_network_policy_v1.tenant[t].spec[0].pod_selector) == 1
      && length(kubernetes_network_policy_v1.tenant[t].spec[0].ingress) == 1
      && length(kubernetes_network_policy_v1.tenant[t].spec[0].egress) == 1
    ])
    error_message = "Each tenant network policy must select every pod and set both ingress and egress."
  }

  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      one(one(kubernetes_network_policy_v1.tenant[t].spec[0].ingress[0].from).namespace_selector).match_labels["kubernetes.io/metadata.name"] == var.monitoring_namespace
      && one(kubernetes_network_policy_v1.tenant[t].spec[0].ingress[0].ports).port == "9252"
    ])
    error_message = "The only ingress to a tenant namespace must be metrics scrapes from the monitoring namespace."
  }

  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      one(one(kubernetes_network_policy_v1.tenant[t].spec[0].egress[0].to).ip_block).cidr == "0.0.0.0/0"
      && toset(one(one(kubernetes_network_policy_v1.tenant[t].spec[0].egress[0].to).ip_block).except) == toset(["169.254.169.254/32"])
    ])
    error_message = "Tenant egress must exclude the EC2 instance metadata endpoint."
  }
}

run "rendered_runner_values_keep_jobs_unprivileged_and_credential_free" {
  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      strcontains(output.runner_helm_values[t], "privileged = false")
      && strcontains(output.runner_helm_values[t], "allow_privilege_escalation = false")
      && strcontains(output.runner_helm_values[t], "namespace = \"ci-${t}\"")
    ])
    error_message = "Job pods must be unprivileged and confined to the tenant namespace."
  }

  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      strcontains(output.runner_helm_values[t], "eks.amazonaws.com/role-arn: ${aws_iam_role.runner[t].arn}")
      && strcontains(output.runner_helm_values[t], "AuthenticationType = \"iam\"")
      && strcontains(output.runner_helm_values[t], "Path = \"${t}\"")
      && !strcontains(lower(output.runner_helm_values[t]), "accesskey")
    ])
    error_message = "The runner manager must use its tenant's IRSA role and cache prefix, with no static AWS keys."
  }

  assert {
    condition = alltrue([
      for t, _ in var.tenants :
      strcontains(output.runner_helm_values[t], "\"workload\" = \"ci\"")
      && strcontains(output.runner_helm_values[t], "\"dedicated=ci\" = \"NoSchedule\"")
      && strcontains(output.runner_helm_values[t], "secret: gitlab-runner-token")
      && !strcontains(output.runner_helm_values[t], "glrt-")
    ])
    error_message = "Job pods must land on the CI node group, and the runner token must come from the Secret, never the values."
  }
}

run "terraform_mode_installs_one_atomic_release_per_tenant" {
  assert {
    condition = (
      toset(keys(helm_release.runner)) == toset(keys(var.tenants))
      && alltrue([
        for t, _ in var.tenants :
        helm_release.runner[t].namespace == "ci-${t}"
        && helm_release.runner[t].version == var.chart_version
        && helm_release.runner[t].atomic && helm_release.runner[t].cleanup_on_fail
      ])
    )
    error_message = "Each tenant gets one atomic release of the pinned chart in its own namespace."
  }
}

run "gitops_mode_installs_no_releases_but_renders_values" {
  variables {
    manage_runner_releases = false
  }

  assert {
    condition     = length(helm_release.runner) == 0 && toset(keys(output.runner_helm_values)) == toset(keys(var.tenants))
    error_message = "In GitOps mode Terraform must render values for every tenant and install nothing."
  }
}

run "rejects_a_plain_http_gitlab_url" {
  command = plan
  variables {
    gitlab_url = "http://gitlab.example.com"
  }
  expect_failures = [var.gitlab_url]
}

run "rejects_a_tenant_key_that_cannot_be_a_namespace" {
  command = plan
  variables {
    tenants = { "Payments" = { runner_token_secret = "gitlab-runner-token" } }
  }
  expect_failures = [var.tenants]
}

run "rejects_an_empty_tenant_set" {
  command = plan
  variables {
    tenants = {}
  }
  expect_failures = [var.tenants]
}

run "rejects_a_malformed_node_taint" {
  command = plan
  variables {
    ci_node_taint = "dedicated"
  }
  expect_failures = [var.ci_node_taint]
}
