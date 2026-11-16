# The values under gitops/tenants are generated from this example by
# `make gitops-values`. This test re-renders them with every provider mocked
# (no AWS, no cluster) and fails when a committed file, tenant set or chart
# version has drifted from what Terraform would write.
#
# The two facts the template takes from AWS, the account in the role ARN and
# cache bucket and the region, are pinned to the example's 123456789012 and
# us-east-1.

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
  mock_data "aws_eks_cluster" {
    defaults = {
      endpoint              = "https://example.eks.amazonaws.com"
      certificate_authority = [{ data = "Y2E=" }]
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE" }] }]
    }
  }
  mock_data "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE" }
  }
}

mock_provider "kubernetes" {}
mock_provider "helm" {}

variables {
  cluster_name  = "platform-prod"
  gitlab_url    = "https://gitlab.example.com"
  chart_version = regex("chart_version\\s*=\\s*\"([^\"]+)\"", file("terraform.tfvars.example"))[0]
  use_gitops    = true
}

run "committed_tenant_values_match_terraform" {
  # Applies against the mocks, so the overridden ARNs below are known.

  # IAM role ARNs are computed by AWS; give each tenant the one its committed
  # values carry.
  override_resource {
    target = module.runner_fleet.aws_iam_role.runner["payments"]
    values = { arn = "arn:aws:iam::123456789012:role/ci-runner-payments" }
  }
  override_resource {
    target = module.runner_fleet.aws_iam_role.runner["platform"]
    values = { arn = "arn:aws:iam::123456789012:role/ci-runner-platform" }
  }

  assert {
    condition = toset(keys(output.runner_helm_values)) == toset([
      for f in fileset("../../../gitops/tenants", "*/values.yaml") : dirname(f)
    ])
    error_message = "The tenants in this example and the folders under gitops/tenants differ; run `make gitops-values` and commit."
  }

  assert {
    condition = alltrue([
      for tenant, rendered in output.runner_helm_values :
      trimspace(replace(rendered, "/^(#[^\n]*\n)*/", "")) ==
      trimspace(replace(file("../../../gitops/tenants/${tenant}/values.yaml"), "/^(#[^\n]*\n)*/", ""))
    ])
    error_message = "A gitops/tenants/<tenant>/values.yaml differs from what Terraform renders; run `make gitops-values` and commit."
  }

  assert {
    condition = alltrue([
      for tenant in keys(output.runner_helm_values) :
      jsondecode(file("../../../gitops/tenants/${tenant}/config.json")) == { tenant = tenant, chartVersion = var.chart_version }
    ])
    error_message = "A gitops/tenants/<tenant>/config.json does not name its folder and the example's chart_version."
  }
}
