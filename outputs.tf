output "kms_key_arn" {
  description = "The ARN of the KMS Key."
  value       = aws_kms_key.fintech_key.arn
}

output "s3_bucket_name" {
  description = "The name of the S3 bucket."
  value       = aws_s3_bucket.payment_events.id
}

output "dynamodb_table_name" {
  description = "The name of the DynamoDB table."
  value       = aws_dynamodb_table.transactions.name
}

output "iam_policy_arn" {
  description = "The ARN of the IAM policy."
  value       = aws_iam_policy.lambda_policy.arn
}

output "lambda_function_name" {
  description = "The name of the Lambda function."
  value       = aws_lambda_function.process_payment_lambda.function_name
}
