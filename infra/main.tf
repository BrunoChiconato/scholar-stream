terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region                      = var.aws_region
  skip_credentials_validation = var.offline_mode
  skip_metadata_api_check     = var.offline_mode
  skip_region_validation      = var.offline_mode
  skip_requesting_account_id  = var.offline_mode
}

data "aws_caller_identity" "current" {
  count = var.offline_mode ? 0 : 1
}
data "aws_region" "current" {}

locals {
  project     = var.project_name
  name_prefix = "${var.project_name}-${var.env}"

  account_id_safe = var.offline_mode ? "000000000000" : data.aws_caller_identity.current[0].account_id

  backup_bucket     = var.s3_backup_bucket != "" ? var.s3_backup_bucket : "scholarstream-firehose-backup-${local.account_id_safe}-${var.aws_region}"
  firehose_name     = var.firehose_name != "" ? var.firehose_name : "scholarstream-openalex"
  cw_log_group_name = "/aws/kinesisfirehose/${local.firehose_name}"
  secret_arn        = var.secret_arn != "" ? var.secret_arn : (var.create_secret ? aws_secretsmanager_secret.snowflake[0].arn : "")
}

resource "aws_s3_bucket" "firehose_backup" {
  bucket        = local.backup_bucket
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "firehose_backup" {
  bucket = aws_s3_bucket.firehose_backup.id
  rule { object_ownership = "BucketOwnerPreferred" }
}

resource "aws_s3_bucket_public_access_block" "firehose_backup" {
  bucket                  = aws_s3_bucket.firehose_backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "firehose_backup" {
  bucket = aws_s3_bucket.firehose_backup.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_cloudwatch_log_group" "firehose" {
  name              = local.cw_log_group_name
  retention_in_days = 14
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

data "aws_iam_policy_document" "assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "firehose" {
  name               = "${local.name_prefix}-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "inline" {
  statement {
    sid    = "S3BackupWrite"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
      "s3:PutObjectAcl"
    ]
    resources = [
      aws_s3_bucket.firehose_backup.arn,
      "${aws_s3_bucket.firehose_backup.arn}/*"
    ]
  }

  statement {
    sid     = "CWLogs"
    effect  = "Allow"
    actions = ["logs:PutLogEvents", "logs:CreateLogStream", "logs:DescribeLogStreams"]
    resources = [
      aws_cloudwatch_log_group.firehose.arn,
      "${aws_cloudwatch_log_group.firehose.arn}:*"
    ]
  }

  dynamic "statement" {
    for_each = local.secret_arn != "" ? [1] : []
    content {
      sid       = "SecretsManagerAccess"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [local.secret_arn]
    }
  }

  dynamic "statement" {
    for_each = var.secret_kms_key_arn != "" ? [1] : []
    content {
      sid       = "SecretsManagerKMS"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [var.secret_kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "firehose" {
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.inline.json
}

resource "aws_secretsmanager_secret" "snowflake" {
  count      = var.create_secret && var.secret_arn == "" ? 1 : 0
  name       = var.secret_name
  kms_key_id = var.secret_kms_key_arn != "" ? var.secret_kms_key_arn : null
}

resource "aws_kinesis_firehose_delivery_stream" "this" {
  name        = local.firehose_name
  destination = "snowflake"

  snowflake_configuration {
    account_url = var.snowflake_account_url
    user        = var.snowflake_user
    role_arn    = aws_iam_role.firehose.arn

    database = var.snowflake_database
    schema   = var.snowflake_schema
    table    = var.snowflake_table

    data_loading_option  = "VARIANT_CONTENT_AND_METADATA_MAPPING"
    content_column_name  = var.content_column_name
    metadata_column_name = var.metadata_column_name

    retry_duration = var.snowflake_retry_seconds

    dynamic "snowflake_role_configuration" {
      for_each = var.snowflake_role != "" ? [1] : []
      content {
        snowflake_role = var.snowflake_role
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose.name
    }

    s3_backup_mode = "FailedDataOnly"
    s3_configuration {
      role_arn            = aws_iam_role.firehose.arn
      bucket_arn          = aws_s3_bucket.firehose_backup.arn
      prefix              = "errors/!{timestamp:yyyy/MM/dd}/"
      error_output_prefix = "errors/!{timestamp:yyyy/MM/dd}/!{firehose:error-output-type}"
      buffering_size      = 5
      buffering_interval  = 60
      compression_format  = "GZIP"

      cloudwatch_logging_options {
        enabled         = true
        log_group_name  = aws_cloudwatch_log_group.firehose.name
        log_stream_name = aws_cloudwatch_log_stream.firehose.name
      }
    }

    secrets_manager_configuration {
      enabled    = true
      secret_arn = local.secret_arn
      role_arn   = aws_iam_role.firehose.arn
    }
  }

  tags = {
    Project     = local.project
    Environment = var.env
  }
}
