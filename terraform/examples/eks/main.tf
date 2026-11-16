# Example: two tenants on an existing EKS cluster.
#
# Creating the cluster itself is out of scope here (use your organization's
# cluster module, or terraform-aws-modules/eks). This root expects a cluster
# with an IAM OIDC provider and a CI node group labeled workload=ci and
# tainted dedicated=ci:NoSchedule.

terraform {
  required_version = ">= 1.6"

  # Remote state with locking. Uncomment and fill in for real use.
  # backend "s3" {
  #   bucket       = "my-org-terraform-state"
  #   key          = "ci/runner-fleet.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }

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

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      ManagedBy = "terraform"
      Component = "gitlab-runner-platform"
    }
  }
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_iam_openid_connect_provider" "this" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# Short-lived token via the AWS CLI instead of a static kubeconfig.
provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}

module "runner_fleet" {
  source = "../../modules/runner-fleet"

  name              = "ci"
  gitlab_url        = var.gitlab_url
  chart_version     = var.chart_version
  oidc_provider_arn = data.aws_iam_openid_connect_provider.this.arn
  oidc_provider_url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer

  manage_runner_releases = !var.use_gitops

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

  tags = {
    CostCenter = "engineering-productivity"
  }
}
