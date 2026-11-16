# Shared S3 build cache. Each tenant reads and writes only under its own
# prefix (see iam.tf), so one tenant cannot poison another's cache.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  cache_bucket = "${var.name}-runner-cache-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
}

resource "aws_s3_bucket" "cache" {
  #checkov:skip=CKV_AWS_18:Access logs for a disposable build cache cost more than they tell; CloudTrail data events cover audit needs
  #checkov:skip=CKV_AWS_21:Cache objects are disposable and expire; versioning would only keep stale caches
  #checkov:skip=CKV_AWS_144:A cache does not need cross-region replication; a lost cache is rebuilt by the next job
  #checkov:skip=CKV2_AWS_62:Nothing consumes cache write events
  bucket        = local.cache_bucket
  force_destroy = true # contents are disposable build caches
  tags          = merge(var.tags, { Purpose = "gitlab-runner-cache" })
}

resource "aws_s3_bucket_ownership_controls" "cache" {
  bucket = aws_s3_bucket.cache.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "cache" {
  bucket                  = aws_s3_bucket.cache.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cache" {
  bucket = aws_s3_bucket.cache.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.cache_kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.cache_kms_key_arn
    }
    bucket_key_enabled = var.cache_kms_key_arn != null
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cache" {
  bucket = aws_s3_bucket.cache.id

  rule {
    id     = "expire-stale-cache"
    status = "Enabled"
    filter {}
    expiration {
      days = var.cache_expiration_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "cache_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.cache.arn,
      "${aws_s3_bucket.cache.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "cache" {
  bucket = aws_s3_bucket.cache.id
  policy = data.aws_iam_policy_document.cache_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.cache]
}
