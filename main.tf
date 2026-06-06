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

# ---------------------------------------------------------------------------
# Local Values — Centralized naming and tagging strategy
# ---------------------------------------------------------------------------
locals {
  environment = terraform.workspace
  common_tags = {
    Project     = "fintech-payments-api"
    Environment = local.environment
    ManagedBy   = "terraform"
    Compliance  = "pci-dss"
  }
}

# ---------------------------------------------------------------------------
# Provider Configuration — Targets LocalStack or real AWS
# ---------------------------------------------------------------------------
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
      s3       = var.localstack_endpoint
      dynamodb = var.localstack_endpoint
      iam      = var.localstack_endpoint
      kms      = var.localstack_endpoint
      lambda   = var.localstack_endpoint
    }
  }
}

# ===========================================================================
# 1. KMS KEY — Customer-Managed Encryption Key (CMK)
#    Provides envelope encryption for S3 and DynamoDB with automatic rotation.
# ===========================================================================
resource "aws_kms_key" "fintech_key" {
  description             = "Customer-managed KMS key for fintech payment data encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  is_enabled              = true

  tags = merge(local.common_tags, {
    Name = "fintech-cmk-${local.environment}"
  })
}

resource "aws_kms_alias" "fintech_key_alias" {
  name          = "alias/fintech-cmk-${local.environment}"
  target_key_id = aws_kms_key.fintech_key.key_id
}

# ===========================================================================
# 2. S3 BUCKET — Encrypted Payment Event Storage
#    Versioned, KMS-encrypted, and fully blocked from public access.
# ===========================================================================
resource "aws_s3_bucket" "payment_events" {
  bucket        = "fintech-payment-events-${local.environment}"
  force_destroy = var.use_localstack # Allow cleanup in local dev only

  tags = merge(local.common_tags, {
    Name      = "fintech-payment-events-${local.environment}"
    DataClass = "confidential"
  })
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
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "pab" {
  bucket                  = aws_s3_bucket.payment_events.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ===========================================================================
# 3. DYNAMODB TABLE — Encrypted Transaction Ledger
#    PAY_PER_REQUEST billing, KMS encryption, point-in-time recovery enabled.
# ===========================================================================
resource "aws_dynamodb_table" "transactions" {
  name         = "transactions-${local.environment}"
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

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, {
    Name      = "transactions-${local.environment}"
    DataClass = "confidential"
  })
}

# ===========================================================================
# 4. IAM — Least-Privilege Lambda Execution Role & Policy
#    Strictly scoped: NO wildcard actions on data services.
# ===========================================================================

# Trust policy: Only the Lambda service principal can assume this role
data "aws_iam_policy_document" "lambda_assume_role_policy" {
  statement {
    sid     = "AllowLambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_payment_processor_role" {
  name               = "lambda-payment-processor-role-${local.environment}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_policy.json

  tags = merge(local.common_tags, {
    Name = "lambda-payment-processor-role-${local.environment}"
  })
}

# Permissions policy: Each statement is scoped to the minimum required action+resource
data "aws_iam_policy_document" "lambda_permissions" {
  # CloudWatch Logs — required for Lambda observability
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }

  # S3 — read-only access to the specific payment events bucket objects
  statement {
    sid       = "AllowS3GetObject"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.payment_events.arn}/*"]
  }

  # DynamoDB — write-only access to the specific transactions table
  statement {
    sid       = "AllowDynamoDBPutItem"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.transactions.arn]
  }

  # KMS — decrypt and generate data keys for the specific CMK only
  statement {
    sid    = "AllowKMSUsage"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey"
    ]
    resources = [aws_kms_key.fintech_key.arn]
  }
}

resource "aws_iam_policy" "lambda_policy" {
  name   = "lambda-payment-processor-policy-${local.environment}"
  policy = data.aws_iam_policy_document.lambda_permissions.json

  tags = merge(local.common_tags, {
    Name = "lambda-payment-processor-policy-${local.environment}"
  })
}

resource "aws_iam_role_policy_attachment" "attach_lambda_policy" {
  role       = aws_iam_role.lambda_payment_processor_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# ===========================================================================
# 5. LAMBDA FUNCTION — Payment Event Processor
#    Reads payment JSON from S3, writes transaction records to DynamoDB.
# ===========================================================================

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/src/process_payment.py"
  output_path = "${path.module}/dist/process_payment.zip"
}

resource "aws_lambda_function" "process_payment_lambda" {
  function_name    = "process-payment-${local.environment}"
  description      = "Processes payment events from S3 and writes transaction records to DynamoDB"
  handler          = "process_payment.handler"
  runtime          = "python3.9"
  role             = aws_iam_role.lambda_payment_processor_role.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = aws_dynamodb_table.transactions.name
    }
  }

  tags = merge(local.common_tags, {
    Name = "process-payment-${local.environment}"
  })
}

# ===========================================================================
# 6. S3 → LAMBDA TRIGGER — Event-Driven Invocation on Object Creation
# ===========================================================================

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.process_payment_lambda.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.payment_events.arn
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.payment_events.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.process_payment_lambda.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
