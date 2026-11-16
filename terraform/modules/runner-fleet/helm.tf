resource "helm_release" "runner" {
  for_each = var.tenants

  name       = "gitlab-runner"
  namespace  = kubernetes_namespace_v1.tenant[each.key].metadata[0].name
  repository = "https://charts.gitlab.io"
  chart      = "gitlab-runner"
  version    = var.chart_version

  atomic          = true # roll back a failed upgrade instead of leaving it half-applied
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

  values = [templatefile("${path.module}/templates/runner-values.yaml.tftpl", {
    tenant             = each.key
    tenant_label       = local.tenant_label
    namespace          = local.namespaces[each.key]
    gitlab_url         = var.gitlab_url
    concurrent         = each.value.concurrent
    token_secret       = each.value.runner_token_secret
    service_account    = local.service_account
    role_arn           = aws_iam_role.runner[each.key].arn
    build_image        = each.value.build_image
    job_cpu_request    = each.value.job_cpu_request
    job_cpu_limit      = each.value.job_cpu_limit
    job_memory_request = each.value.job_memory_request
    job_memory_limit   = each.value.job_memory_limit
    node_selector      = var.ci_node_selector
    node_taint         = var.ci_node_taint
    cache_bucket       = aws_s3_bucket.cache.bucket
    cache_region       = data.aws_region.current.name
  })]

  depends_on = [
    kubernetes_resource_quota_v1.tenant,
    kubernetes_limit_range_v1.tenant,
    kubernetes_network_policy_v1.tenant,
    aws_iam_role_policy.runner_cache,
  ]
}
