variable "region" {
  description = "AWS region of the EKS cluster."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the existing EKS cluster."
  type        = string
}

variable "gitlab_url" {
  description = "Base URL of your GitLab instance."
  type        = string
  default     = "https://gitlab.com"
}

variable "chart_version" {
  description = "gitlab-runner Helm chart version to pin (see `helm search repo gitlab/gitlab-runner --versions`)."
  type        = string
}
