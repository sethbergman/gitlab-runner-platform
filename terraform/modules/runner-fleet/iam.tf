# One IAM role per tenant, assumed through IRSA by that tenant's runner
# manager only. The manager signs pre-signed URLs that job pods use for the
# cache, so job pods themselves get no AWS credentials.

locals {
  oidc_issuer = trimprefix(var.oidc_provider_url, "https://")
}

data "aws_iam_policy_document" "runner_trust" {
  for_each = var.tenants

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${local.namespaces[each.key]}:${local.service_account}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "runner_cache" {
  for_each = var.tenants

  statement {
    sid       = "ListOwnPrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.cache.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.key}/*"]
    }
  }

  statement {
    sid = "ReadWriteOwnPrefix"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${aws_s3_bucket.cache.arn}/${each.key}/*"]
  }

  dynamic "statement" {
    for_each = var.cache_kms_key_arn == null ? [] : [var.cache_kms_key_arn]
    content {
      sid       = "UseCacheKey"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role" "runner" {
  for_each = var.tenants

  name                 = "${var.name}-runner-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.runner_trust[each.key].json
  max_session_duration = 3600
  tags                 = merge(var.tags, { Tenant = each.key })
}

resource "aws_iam_role_policy" "runner_cache" {
  for_each = var.tenants

  name   = "runner-cache"
  role   = aws_iam_role.runner[each.key].id
  policy = data.aws_iam_policy_document.runner_cache[each.key].json
}
