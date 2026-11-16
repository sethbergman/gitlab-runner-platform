output "cache_bucket" {
  description = "Name of the shared S3 cache bucket."
  value       = aws_s3_bucket.cache.bucket
}

output "tenant_namespaces" {
  description = "Namespace of each tenant's runner manager and job pods."
  value       = local.namespaces
}

output "runner_role_arns" {
  description = "IRSA role ARN of each tenant's runner manager."
  value       = { for k, r in aws_iam_role.runner : k => r.arn }
}

output "runner_helm_values" {
  description = "Rendered gitlab-runner chart values per tenant. In GitOps mode, commit these to gitops/tenants/<tenant>/values.yaml (make gitops-values)."
  value       = local.runner_values
}
