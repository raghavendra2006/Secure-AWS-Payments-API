terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region                      = var.aws_region
  access_key                  = var.use_localstack ? "test" : null
  secret_key                  = var.use_localstack ? "test" : null
  skip_credentials_validation = var.use_localstack
  skip_metadata_api_check     = var.use_localstack
  skip_requesting_account_id  = var.use_localstack
  s3_use_path_style           = var.use_localstack

  dynamic "endpoints" {
    for_each = var.use_localstack ? [1] : []
    content {
      s3       = "http://localhost:4566"
      dynamodb = "http://localhost:4566"
      iam      = "http://localhost:4566"
      kms      = "http://localhost:4566"
      lambda   = "http://localhost:4566"
    }
  }
}

# 1. KMS Key for Data Encryption
resource "aws_kms_key" "fintech_key" {
  description             = "KMS key for fintech app data encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

# 2. S3 Bucket for Payment Events
resource "aws_s3_bucket" "payment_events" {
  bucket = "fintech-payment-events-${terraform.workspace}"
}

resource "aws_s3_bucket_versioning" "versioning_example" {
  bucket = aws_s3_bucket.payment_events.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "encryption_config" {
  bucket = aws_s3_bucket.payment_events.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.fintech_key.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "pab" {
  bucket                  = aws_s3_bucket.payment_events.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 3. DynamoDB Table for Transactions
resource "aws_dynamodb_table" "transactions" {
  name         = "transactions-${terraform.workspace}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "TransactionID"

  attribute {
    name = "TransactionID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.fintech_key.arn
  }
}

# 4. IAM Role and Policies for the Lambda Function
data "aws_iam_policy_document" "lambda_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_payment_processor_role" {
  name               = "lambda-payment-processor-role-${terraform.workspace}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_policy.json
}

data "aws_iam_policy_document" "lambda_permissions" {
  # CloudWatch Logs permissions
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }

  # S3 read permission for the specific bucket
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.payment_events.arn}/*"]
  }

  # DynamoDB write permission for the specific table
  statement {
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.transactions.arn]
  }

  # KMS permissions for decrypting files from S3 and writing encrypted data to DynamoDB
  statement {
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey"
    ]
    resources = [aws_kms_key.fintech_key.arn]
  }
}

resource "aws_iam_policy" "lambda_policy" {
  name   = "lambda-payment-processor-policy-${terraform.workspace}"
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

resource "aws_iam_role_policy_attachment" "attach_lambda_policy" {
  role       = aws_iam_role.lambda_payment_processor_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# 5. Archive Lambda Function Code
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/src/process_payment.py"
  output_path = "${path.module}/dist/process_payment.zip"
}

# 6. Lambda Function
resource "aws_lambda_function" "process_payment_lambda" {
  function_name    = "process-payment-${terraform.workspace}"
  handler          = "process_payment.handler"
  runtime          = "python3.9"
  role             = aws_iam_role.lambda_payment_processor_role.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = aws_dynamodb_table.transactions.name
    }
  }
}

# 7. S3 Bucket Trigger for Lambda Function
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.payment_events.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.process_payment_lambda.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.process_payment_lambda.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.payment_events.arn
}
