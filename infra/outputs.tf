output "firehose_stream_name" {
  value       = aws_kinesis_firehose_delivery_stream.this.name
  description = "Firehose delivery stream name"
}

output "firehose_stream_arn" {
  value       = aws_kinesis_firehose_delivery_stream.this.arn
  description = "Firehose delivery stream ARN"
}

output "backup_bucket" {
  value       = aws_s3_bucket.firehose_backup.bucket
  description = "S3 bucket used for error backups"
}

output "cloudwatch_log_group" {
  value       = aws_cloudwatch_log_group.firehose.name
  description = "CloudWatch Logs group for Firehose"
}

output "secret_arn" {
  value       = var.create_secret ? aws_secretsmanager_secret.snowflake[0].arn : null
  description = "Secrets Manager secret ARN (if created)"
}
