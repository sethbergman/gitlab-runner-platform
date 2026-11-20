variable "name" {
  description = "Short name for this fleet, used in AWS resource names."
  type        = string
  default     = "ci"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,20}$", var.name))
    error_message = "name must be 2-20 lowercase letters, digits or hyphens."
  }
}

variable "gitlab_url" {
  description = "Base URL of the GitLab instance the runners register with."
  type        = string

  validation {
    condition     = startswith(var.gitlab_url, "https://")
    error_message = "gitlab_url must use https."
  }
}

variable "gitlab_ca_secret" {
  description = <<-EOT
    For a GitLab whose certificate a private CA signs: the name of a Secret
    in each tenant namespace holding that CA as <gitlab host>.crt, which the
    runner trusts (the chart's certsSecretName). Sync it from your secret
    store like the runner token. Leave null for a publicly trusted
    certificate.
  EOT
  type        = string
  default     = null
}

variable "chart_version" {
  description = "gitlab-runner Helm chart version. Pin it, and move it deliberately alongside your GitLab version."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster's IAM OIDC provider, for IRSA."
  type        = string
}

variable "oidc_provider_url" {
  description = "Issuer URL of the EKS cluster's OIDC provider, with or without https://."
  type        = string
}

variable "tenants" {
  description = <<-EOT
    One runner manager per tenant, each in its own namespace (ci-<key>) with
    its own quota, network policy and cache prefix. The runner authentication
    token (glrt-...) is never passed to Terraform: create a Kubernetes Secret
    named runner_token_secret in the tenant namespace, with keys
    runner-token and runner-registration-token (empty), from your secret store.
    Runner tags are set on the runner in GitLab, not here.
  EOT
  type = map(object({
    runner_token_secret = string
    concurrent          = optional(number, 20)
    build_image         = optional(string, "alpine:3.20")
    job_cpu_request     = optional(string, "500m")
    job_cpu_limit       = optional(string, "2")
    job_memory_request  = optional(string, "1Gi")
    job_memory_limit    = optional(string, "4Gi")
    quota_cpu_requests  = optional(string, "40")
    quota_mem_requests  = optional(string, "80Gi")
    quota_cpu_limits    = optional(string, "80")
    quota_mem_limits    = optional(string, "160Gi")
    quota_pods          = optional(number, 60)
  }))

  validation {
    condition     = alltrue([for k in keys(var.tenants) : can(regex("^[a-z0-9-]{2,30}$", k))])
    error_message = "Tenant keys must be 2-30 lowercase letters, digits or hyphens (they become namespace names)."
  }
  validation {
    condition     = length(var.tenants) > 0
    error_message = "Define at least one tenant."
  }
}

variable "ci_node_selector" {
  description = "Node labels that CI job pods must land on (a dedicated node group)."
  type        = map(string)
  default     = { workload = "ci" }
}

variable "ci_node_taint" {
  description = "Taint on the CI node group, as key=value. Job pods tolerate it with effect NoSchedule."
  type        = string
  default     = "dedicated=ci"

  validation {
    condition     = can(regex("^[^=]+=[^=]+$", var.ci_node_taint))
    error_message = "ci_node_taint must look like key=value."
  }
}

variable "cache_expiration_days" {
  description = "Delete cache objects after this many days. Caches are disposable; old ones only cost money."
  type        = number
  default     = 14
}

variable "cache_kms_key_arn" {
  description = "Optional KMS key for cache encryption. Defaults to SSE-S3."
  type        = string
  default     = null
}

variable "monitoring_namespace" {
  description = "Namespace allowed to scrape runner-manager metrics."
  type        = string
  default     = "monitoring"
}

variable "tags" {
  description = "Tags applied to every AWS resource."
  type        = map(string)
  default     = {}
}

variable "manage_runner_releases" {
  description = <<-EOT
    true: Terraform installs each tenant's runner with helm_release.
    false: GitOps mode. Terraform still owns AWS and the tenant guardrails,
    but Argo CD installs the runners from values committed to Git; get them
    from the runner_helm_values output (see docs/gitops.md).
  EOT
  type        = bool
  default     = true
}
