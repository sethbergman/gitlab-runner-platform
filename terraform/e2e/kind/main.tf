# The runner-fleet module applied for real: Kubernetes objects and Helm
# releases on a kind cluster, S3, IAM and STS served by moto. Driven by
# .github/scripts/terraform-e2e.sh (make terraform-e2e), which runs
# Terraform in a container on the kind network. Not an example to copy;
# terraform/examples/eks is that.

terraform {
  required_version = ">= 1.6"

  # The script points this at a throwaway directory, so a run never leaves
  # state in the repository.
  backend "local" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 6.74"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.27, < 3.6"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0, < 3.4"
    }
  }
}

# moto runs on the kind network as "moto", and also as "123456789012.moto":
# S3 Control, which the provider reads bucket tags through, puts the account
# ID in front of the endpoint's host name.
variable "moto_endpoint" {
  description = "Where moto serves the AWS APIs."
  type        = string
  default     = "https://moto:5000"
}

variable "moto_ca_bundle" {
  description = "The throwaway CA that signs moto's certificate."
  type        = string
}

variable "kubeconfig" {
  description = "kubeconfig of the kind cluster, with its address on the kind network."
  type        = string
}

variable "chart_version" {
  description = "gitlab-runner chart version, the one the tenants pin."
  type        = string
}

# Credentials come from AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, which
# the script sets to dummies: moto accepts any.
provider "aws" {
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  s3_use_path_style           = true
  custom_ca_bundle            = var.moto_ca_bundle

  endpoints {
    iam       = var.moto_endpoint
    s3        = var.moto_endpoint
    s3control = var.moto_endpoint
    sts       = var.moto_endpoint
  }

  default_tags {
    tags = {
      ManagedBy = "terraform-e2e"
    }
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig
}

provider "helm" {
  kubernetes = {
    config_path = var.kubeconfig
  }
}

# What EKS creates for a cluster: an IAM OIDC provider for IRSA. kind has no
# issuer AWS could reach, so IRSA itself is not exercised; the roles' trust
# policies name this provider as they would a real one.
resource "aws_iam_openid_connect_provider" "cluster" {
  url            = "https://oidc.e2e.test/id/KIND"
  client_id_list = ["sts.amazonaws.com"]
}

module "runner_fleet" {
  source = "../../modules/runner-fleet"

  name          = "e2e"
  chart_version = var.chart_version

  # The script's GitLab stand-in, under a throwaway CA the runners trust
  # through a Secret the script's secret-store stand-in syncs.
  gitlab_url       = "https://gitlab.e2e.test"
  gitlab_ca_secret = "gitlab-ca"

  oidc_provider_arn = aws_iam_openid_connect_provider.cluster.arn
  oidc_provider_url = aws_iam_openid_connect_provider.cluster.url

  # The two tenants the EKS example defines, with its overrides.
  tenants = {
    payments = {
      runner_token_secret = "gitlab-runner-token"
      concurrent          = 30
      job_memory_limit    = "6Gi"
    }
    platform = {
      runner_token_secret = "gitlab-runner-token"
      concurrent          = 15
      quota_pods          = 30
    }
  }
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.cluster.arn
}

output "cache_bucket" {
  value = module.runner_fleet.cache_bucket
}

output "tenant_namespaces" {
  value = module.runner_fleet.tenant_namespaces
}

output "runner_role_arns" {
  value = module.runner_fleet.runner_role_arns
}
