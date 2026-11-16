output "cache_bucket" {
  value = module.runner_fleet.cache_bucket
}

output "tenant_namespaces" {
  value = module.runner_fleet.tenant_namespaces
}

output "runner_role_arns" {
  value = module.runner_fleet.runner_role_arns
}

output "runner_helm_values" {
  description = "Rendered runner values per tenant, written to gitops/tenants by `make gitops-values`."
  value       = module.runner_fleet.runner_helm_values
}

output "chart_version" {
  description = "Pinned gitlab-runner chart version, copied into gitops/tenants/*/config.json."
  value       = var.chart_version
}
