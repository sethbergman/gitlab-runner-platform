output "cache_bucket" {
  value = module.runner_fleet.cache_bucket
}

output "tenant_namespaces" {
  value = module.runner_fleet.tenant_namespaces
}

output "runner_role_arns" {
  value = module.runner_fleet.runner_role_arns
}
