# Each tenant gets a namespace that holds its runner manager and its job pods,
# fenced in by Pod Security admission, a quota, default limits and network
# policy. This is the blast-radius boundary between teams.

locals {
  service_account = "gitlab-runner"
  namespaces      = { for k, _ in var.tenants : k => "ci-${k}" }
  tenant_label    = "platform.ci/tenant"
}

resource "kubernetes_namespace_v1" "tenant" {
  for_each = var.tenants

  metadata {
    name = local.namespaces[each.key]
    labels = {
      (local.tenant_label) = each.key
      # Builds commonly need root inside the container, so enforce "baseline"
      # (no privileged pods, host namespaces or hostPath) and warn/audit
      # against "restricted" to show teams how far they are from it.
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
    }
  }
}

resource "kubernetes_resource_quota_v1" "tenant" {
  for_each = var.tenants

  metadata {
    name      = "ci-quota"
    namespace = kubernetes_namespace_v1.tenant[each.key].metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = each.value.quota_cpu_requests
      "requests.memory" = each.value.quota_mem_requests
      "limits.cpu"      = each.value.quota_cpu_limits
      "limits.memory"   = each.value.quota_mem_limits
      "pods"            = each.value.quota_pods
    }
  }
}

# Containers that set no resources (e.g. services a job declares) still get
# sane defaults, so the quota can admit them.
resource "kubernetes_limit_range_v1" "tenant" {
  for_each = var.tenants

  metadata {
    name      = "ci-defaults"
    namespace = kubernetes_namespace_v1.tenant[each.key].metadata[0].name
  }
  spec {
    limit {
      type = "Container"
      default_request = {
        cpu    = "250m"
        memory = "256Mi"
      }
      default = {
        cpu    = "1"
        memory = "1Gi"
      }
    }
  }
}

# Ingress: nothing, except metrics scrapes from the monitoring namespace.
# Egress: anywhere but the EC2 instance metadata endpoint, so a build cannot
# borrow the node's IAM role.
resource "kubernetes_network_policy_v1" "tenant" {
  for_each = var.tenants

  metadata {
    name      = "ci-isolation"
    namespace = kubernetes_namespace_v1.tenant[each.key].metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.monitoring_namespace
          }
        }
      }
      ports {
        port     = "9252"
        protocol = "TCP"
      }
    }

    egress {
      to {
        ip_block {
          cidr   = "0.0.0.0/0"
          except = ["169.254.169.254/32"]
        }
      }
    }
  }
}
