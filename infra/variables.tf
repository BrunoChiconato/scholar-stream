variable "project_name" {
  description = "Project prefix for naming"
  type        = string
  default     = "scholarstream"
}

variable "env" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "firehose_name" {
  description = "Firehose delivery stream name"
  type        = string
  default     = ""
}

variable "s3_backup_bucket" {
  description = "Existing S3 bucket name for error backup (optional)"
  type        = string
  default     = ""
}

variable "snowflake_account_url" {
  description = "Snowflake PUBLIC account URL (e.g., <acct>.<region>.aws.snowflakecomputing.com)"
  type        = string
}

variable "snowflake_user" {
  description = "Snowflake user used by Firehose"
  type        = string
}

variable "snowflake_role" {
  description = "Optional Snowflake role to assume (otherwise default role of the user is used)"
  type        = string
  default     = ""
}

variable "snowflake_database" {
  description = "Target database"
  type        = string
  default     = "SCHOLARSTREAM"
}

variable "snowflake_schema" {
  description = "Target schema"
  type        = string
  default     = "RAW"
}

variable "snowflake_table" {
  description = "Target table"
  type        = string
  default     = "OPENALEX_EVENTS"
}

variable "content_column_name" {
  description = "VARIANT column name for raw payload"
  type        = string
  default     = "RECORD"
}

variable "metadata_column_name" {
  description = "Column name for metadata"
  type        = string
  default     = "RECORD_METADATA"
}

variable "snowflake_retry_seconds" {
  description = "Retry duration when Snowflake is temporarily unavailable (0-7200)"
  type        = number
  default     = 300
}

variable "create_secret" {
  description = "Create a Secrets Manager secret for Snowflake credentials"
  type        = bool
  default     = true
}

variable "secret_name" {
  description = "Name for Secrets Manager secret (only if create_secret = true)"
  type        = string
  default     = "scholarstream/snowflake/firehose"
}

variable "secret_kms_key_arn" {
  description = "KMS CMK ARN for encrypting the secret (optional)"
  type        = string
  default     = ""
}

variable "secret_arn" {
  description = "Use an existing secret ARN instead of creating one"
  type        = string
  default     = ""
}

variable "offline_mode" {
  description = "Skip AWS credentials/account/metadata checks (plan-only in CI)"
  type        = bool
  default     = false
}