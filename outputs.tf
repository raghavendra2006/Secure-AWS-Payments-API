output "kms_key_arn" {
  description = "The ARN of the customer-managed KMS Key."
  value       = aws_kms_key.fintech_key.arn
}

output "kms_key_id" {
  description = "The ID of the customer-managed KMS Key."
  value       = aws_kms_key.fintech_key.key_id
}

output "kms_alias_name" {
  description = "The alias name of the KMS Key."
  value       = aws_kms_alias.fintech_key_alias.name
}

output "s3_bucket_name" {
  description = "The name of the S3 bucket for payment events."
  value       = aws_s3_bucket.payment_events.id
}

output "s3_bucket_arn" {
  description = "The ARN of the S3 bucket for payment events."
  value       = aws_s3_bucket.payment_events.arn
}

output "dynamodb_table_name" {
  description = "The name of the DynamoDB transactions table."
  value       = aws_dynamodb_table.transactions.name
}

output "dynamodb_table_arn" {
  description = "The ARN of the DynamoDB transactions table."
  value       = aws_dynamodb_table.transactions.arn
}

output "iam_role_arn" {
  description = "The ARN of the Lambda execution IAM role."
  value       = aws_iam_role.lambda_payment_processor_role.arn
}

output "iam_policy_arn" {
  description = "The ARN of the Lambda permissions IAM policy."
  value       = aws_iam_policy.lambda_policy.arn
}

output "lambda_function_name" {
  description = "The name of the Lambda function."
  value       = aws_lambda_function.process_payment_lambda.function_name
}

output "lambda_function_arn" {
  description = "The ARN of the Lambda function."
  value       = aws_lambda_function.process_payment_lambda.arn
}
