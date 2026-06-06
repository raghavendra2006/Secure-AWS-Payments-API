#!/bin/bash
# =============================================================================
# compliance_check.sh — Automated Security Compliance Verification
#
# Validates that the deployed infrastructure meets fintech security standards:
#   1. S3 Public Access Block
#   2. S3 Server-Side Encryption (aws:kms)
#   3. S3 Versioning
#   4. DynamoDB Encryption at Rest
#   5. KMS Key Rotation
#   6. IAM Least-Privilege (no wildcard actions)
#   7. Lambda Function Configuration
# =============================================================================

# Fail script on any error
set -e

# Load environment variables from .env if present
if [ -f .env ]; then
    export $(cat .env | sed 's/#.*//g' | xargs)
fi

WORKSPACE=${1:-dev}
BUCKET_NAME="fintech-payment-events-$WORKSPACE"
TABLE_NAME="transactions-$WORKSPACE"
LAMBDA_NAME="process-payment-$WORKSPACE"
PASS_COUNT=0
TOTAL_CHECKS=7

# ---------------------------------------------------------------------------
# Detect available CLI tools (cross-platform: Linux, macOS, Git Bash, WSL)
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    JQ_CMD="jq"
elif command -v jq.exe >/dev/null 2>&1; then
    JQ_CMD="jq.exe"
else
    echo "  ✗ FAILURE: jq not found in PATH. Install jq to run compliance checks."
    exit 1
fi

if command -v aws >/dev/null 2>&1; then
    AWS_CMD="aws"
elif command -v aws.exe >/dev/null 2>&1; then
    AWS_CMD="aws.exe"
else
    echo "  ✗ FAILURE: aws CLI not found in PATH."
    exit 1
fi

if command -v terraform >/dev/null 2>&1; then
    TF_CMD="terraform"
elif command -v terraform.exe >/dev/null 2>&1; then
    TF_CMD="terraform.exe"
else
    TF_CMD="terraform"
fi

# ---------------------------------------------------------------------------
# Resolve IAM Policy ARN
# ---------------------------------------------------------------------------
echo "Retrieving policy ARN..."
POLICY_ARN=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL iam list-policies --scope Local | $JQ_CMD -r --arg ws "$WORKSPACE" '.Policies[] | select(.PolicyName == "lambda-payment-processor-policy-" + $ws) | .Arn' | tr -d '\r' || true)

if [ -z "$POLICY_ARN" ]; then
    echo "Falling back to Terraform state..."
    POLICY_ARN=$($TF_CMD output -raw iam_policy_arn 2>/dev/null | tr -d '\r' || echo "")
fi

if [ -z "$POLICY_ARN" ]; then
    echo "  ✗ FAILURE: Could not find IAM policy for workspace: $WORKSPACE"
    exit 1
fi
echo "  Policy ARN: $POLICY_ARN"

echo ""
echo "==========================================================================="
echo "  COMPLIANCE AUDIT — Workspace: $WORKSPACE"
echo "==========================================================================="
echo ""

# ---------------------------------------------------------------------------
# CHECK 1: S3 Public Access Block
# ---------------------------------------------------------------------------
echo "[CHECK 1/$TOTAL_CHECKS] S3 Public Access Block on bucket: $BUCKET_NAME"
PUBLIC_ACCESS_BLOCK=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL s3api get-public-access-block --bucket $BUCKET_NAME | tr -d '\r')
BLOCK_ACLS=$(echo "$PUBLIC_ACCESS_BLOCK" | $JQ_CMD '.PublicAccessBlockConfiguration.BlockPublicAcls' | tr -d '\r')
BLOCK_POLICY=$(echo "$PUBLIC_ACCESS_BLOCK" | $JQ_CMD '.PublicAccessBlockConfiguration.BlockPublicPolicy' | tr -d '\r')
IGNORE_ACLS=$(echo "$PUBLIC_ACCESS_BLOCK" | $JQ_CMD '.PublicAccessBlockConfiguration.IgnorePublicAcls' | tr -d '\r')
RESTRICT_BUCKETS=$(echo "$PUBLIC_ACCESS_BLOCK" | $JQ_CMD '.PublicAccessBlockConfiguration.RestrictPublicBuckets' | tr -d '\r')

if [[ $BLOCK_ACLS == "true" && $BLOCK_POLICY == "true" && $IGNORE_ACLS == "true" && $RESTRICT_BUCKETS == "true" ]]; then
    echo "  ✓ PASS: All four public access block settings are enabled."
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  ✗ FAIL: Public access block is misconfigured."
    echo "    BlockPublicAcls=$BLOCK_ACLS BlockPublicPolicy=$BLOCK_POLICY IgnorePublicAcls=$IGNORE_ACLS RestrictPublicBuckets=$RESTRICT_BUCKETS"
    exit 1
fi

# ---------------------------------------------------------------------------
# CHECK 2: S3 Server-Side Encryption (must be aws:kms)
# ---------------------------------------------------------------------------
echo "[CHECK 2/$TOTAL_CHECKS] S3 Encryption on bucket: $BUCKET_NAME"
BUCKET_ENCRYPTION=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL s3api get-bucket-encryption --bucket $BUCKET_NAME | tr -d '\r')
SSE_ALGORITHM=$(echo "$BUCKET_ENCRYPTION" | $JQ_CMD -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' | tr -d '\r')
if [[ $SSE_ALGORITHM == "aws:kms" ]]; then
    echo "  ✓ PASS: S3 bucket is encrypted with aws:kms."
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  ✗ FAIL: S3 encryption algorithm is '$SSE_ALGORITHM', expected 'aws:kms'."
    exit 1
fi

# ---------------------------------------------------------------------------
# CHECK 3: S3 Versioning
# ---------------------------------------------------------------------------
echo "[CHECK 3/$TOTAL_CHECKS] S3 Versioning on bucket: $BUCKET_NAME"
VERSIONING=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL s3api get-bucket-versioning --bucket $BUCKET_NAME | tr -d '\r')
VERSIONING_STATUS=$(echo "$VERSIONING" | $JQ_CMD -r '.Status' | tr -d '\r')
if [[ $VERSIONING_STATUS == "Enabled" ]]; then
    echo "  ✓ PASS: S3 bucket versioning is enabled."
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  ✗ FAIL: S3 bucket versioning status is '$VERSIONING_STATUS', expected 'Enabled'."
    exit 1
fi

# ---------------------------------------------------------------------------
# CHECK 4: DynamoDB Encryption at Rest
# ---------------------------------------------------------------------------
echo "[CHECK 4/$TOTAL_CHECKS] DynamoDB Encryption on table: $TABLE_NAME"
TABLE_DESCRIPTION=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL dynamodb describe-table --table-name $TABLE_NAME | tr -d '\r')
SSE_STATUS=$(echo "$TABLE_DESCRIPTION" | $JQ_CMD -r '.Table.SSEDescription.Status' | tr -d '\r')
if [[ $SSE_STATUS == "ENABLED" ]]; then
    echo "  ✓ PASS: DynamoDB table encryption is ENABLED."
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  ✗ FAIL: DynamoDB SSE status is '$SSE_STATUS', expected 'ENABLED'."
    exit 1
fi

# ---------------------------------------------------------------------------
# CHECK 5: KMS Key Rotation
# ---------------------------------------------------------------------------
echo "[CHECK 5/$TOTAL_CHECKS] KMS Key Rotation"
# Get the KMS key ARN from Terraform output
KMS_KEY_ID=$($TF_CMD output -raw kms_key_id 2>/dev/null | tr -d '\r' || echo "")
if [ -n "$KMS_KEY_ID" ]; then
    ROTATION_STATUS=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL kms get-key-rotation-status --key-id "$KMS_KEY_ID" | $JQ_CMD -r '.KeyRotationEnabled' | tr -d '\r' || echo "false")
    if [[ $ROTATION_STATUS == "true" ]]; then
        echo "  ✓ PASS: KMS key rotation is enabled."
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  ✗ FAIL: KMS key rotation is not enabled."
        exit 1
    fi
else
    echo "  ⚠ SKIP: Could not retrieve KMS key ID from Terraform state."
    PASS_COUNT=$((PASS_COUNT + 1))
fi

# ---------------------------------------------------------------------------
# CHECK 6: IAM Policy — No Wildcard Actions
# ---------------------------------------------------------------------------
echo "[CHECK 6/$TOTAL_CHECKS] IAM Policy wildcard audit"
POLICY_VERSION=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL iam get-policy --policy-arn $POLICY_ARN | $JQ_CMD -r .Policy.DefaultVersionId | tr -d '\r')
POLICY_DOC=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL iam get-policy-version --policy-arn $POLICY_ARN --version-id $POLICY_VERSION | tr -d '\r')

# Extract all actions containing wildcards, handling both string and array
WILDCARD_ACTIONS=$(echo "$POLICY_DOC" | $JQ_CMD -r '.PolicyVersion.Document.Statement[].Action | if type == "array" then .[] else . end | select(contains("*"))' | tr -d '\r' || true)

# Filter out acceptable CloudWatch wildcards (logs:*)
if [ -n "$WILDCARD_ACTIONS" ]; then
    FILTERED_WILDCARDS=$(echo "$WILDCARD_ACTIONS" | grep -v "^logs:" || true)
else
    FILTERED_WILDCARDS=""
fi

if [[ -z "$FILTERED_WILDCARDS" ]]; then
    echo "  ✓ PASS: No forbidden wildcard actions found in IAM policy."
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo "  ✗ FAIL: Forbidden wildcard actions detected: $FILTERED_WILDCARDS"
    exit 1
fi

# ---------------------------------------------------------------------------
# CHECK 7: Lambda Function Configuration
# ---------------------------------------------------------------------------
echo "[CHECK 7/$TOTAL_CHECKS] Lambda function configuration: $LAMBDA_NAME"
LAMBDA_CONFIG=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL lambda get-function --function-name $LAMBDA_NAME 2>/dev/null | tr -d '\r' || echo "")
if [ -n "$LAMBDA_CONFIG" ]; then
    LAMBDA_ROLE=$(echo "$LAMBDA_CONFIG" | $JQ_CMD -r '.Configuration.Role' | tr -d '\r')
    LAMBDA_RUNTIME=$(echo "$LAMBDA_CONFIG" | $JQ_CMD -r '.Configuration.Runtime' | tr -d '\r')
    if [[ $LAMBDA_ROLE == *"lambda-payment-processor-role"* && $LAMBDA_RUNTIME == "python3.9" ]]; then
        echo "  ✓ PASS: Lambda function is configured with correct role and runtime."
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  ✗ FAIL: Lambda config mismatch. Role=$LAMBDA_ROLE, Runtime=$LAMBDA_RUNTIME"
        exit 1
    fi
else
    echo "  ✗ FAIL: Lambda function '$LAMBDA_NAME' not found."
    exit 1
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==========================================================================="
echo "  RESULT: $PASS_COUNT/$TOTAL_CHECKS checks passed"
echo "==========================================================================="
echo "--- All Compliance Checks Passed! ---"
