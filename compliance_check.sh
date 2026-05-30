#!/bin/bash
# compliance_check.sh

# Fail script on any error
set -e

# Add common user bin paths on Windows/Linux to PATH to make sure jq/aws are found
export PATH=$PATH:/c/Users/patch/.local/bin:/usr/local/bin:/mnt/c/Users/patch/.local/bin

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | sed 's/#.*//g' | xargs)
fi

WORKSPACE=${1:-dev} # Default to 'dev' workspace if no argument is provided
BUCKET_NAME="fintech-payment-events-$WORKSPACE"
TABLE_NAME="transactions-$WORKSPACE"

# Detect and setup commands
if command -v jq >/dev/null 2>&1; then
    JQ_CMD="jq"
elif command -v jq.exe >/dev/null 2>&1; then
    JQ_CMD="jq.exe"
else
    echo "  ✗ FAILURE: jq or jq.exe not found in PATH"
    exit 1
fi

if command -v aws >/dev/null 2>&1; then
    AWS_CMD="aws"
elif command -v aws.exe >/dev/null 2>&1; then
    AWS_CMD="aws.exe"
else
    echo "  ✗ FAILURE: aws or aws.exe not found in PATH"
    exit 1
fi

if command -v terraform >/dev/null 2>&1; then
    TF_CMD="terraform"
elif command -v terraform.exe >/dev/null 2>&1; then
    TF_CMD="terraform.exe"
else
    TF_CMD="terraform"
fi

# Resolve POLICY_ARN using AWS CLI first, fall back to Terraform if needed
echo "Retrieving policy ARN..."
POLICY_ARN=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL iam list-policies --scope Local | $JQ_CMD -r --arg ws "$WORKSPACE" '.Policies[] | select(.PolicyName == "lambda-payment-processor-policy-" + $ws) | .Arn' | tr -d '\r' || true)

if [ -z "$POLICY_ARN" ]; then
    echo "Using Terraform state to retrieve policy ARN..."
    POLICY_ARN=$($TF_CMD output -raw iam_policy_arn 2>/dev/null | tr -d '\r' || echo "")
fi

if [ -z "$POLICY_ARN" ]; then
    echo "  ✗ FAILURE: Could not find IAM policy for workspace: $WORKSPACE"
    exit 1
fi

echo "--- Running Compliance Checks for workspace: $WORKSPACE ---"

# 1. Check S3 Public Access Block
echo "[CHECK 1] Verifying S3 Public Access Block on bucket: $BUCKET_NAME..."
PUBLIC_ACCESS_BLOCK=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL s3api get-public-access-block --bucket $BUCKET_NAME | tr -d '\r')
BLOCK_ACLS=$(echo "$PUBLIC_ACCESS_BLOCK" | $JQ_CMD '.PublicAccessBlockConfiguration.BlockPublicAcls' | tr -d '\r')
BLOCK_POLICY=$(echo "$PUBLIC_ACCESS_BLOCK" | $JQ_CMD '.PublicAccessBlockConfiguration.BlockPublicPolicy' | tr -d '\r')
IGNORE_ACLS=$(echo "$PUBLIC_ACCESS_BLOCK" | $JQ_CMD '.PublicAccessBlockConfiguration.IgnorePublicAcls' | tr -d '\r')
RESTRICT_BUCKETS=$(echo "$PUBLIC_ACCESS_BLOCK" | $JQ_CMD '.PublicAccessBlockConfiguration.RestrictPublicBuckets' | tr -d '\r')

if [[ $BLOCK_ACLS == "true" && $BLOCK_POLICY == "true" && $IGNORE_ACLS == "true" && $RESTRICT_BUCKETS == "true" ]]; then
    echo "  ✓ SUCCESS: S3 bucket has public access block fully enabled."
else
    echo "  ✗ FAILURE: S3 public access block is not correctly configured."
    echo "  Found: BlockPublicAcls=$BLOCK_ACLS, BlockPublicPolicy=$BLOCK_POLICY, IgnorePublicAcls=$IGNORE_ACLS, RestrictPublicBuckets=$RESTRICT_BUCKETS"
    exit 1
fi

# 2. Check S3 Encryption
echo "[CHECK 2] Verifying S3 Encryption on bucket: $BUCKET_NAME..."
BUCKET_ENCRYPTION=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL s3api get-bucket-encryption --bucket $BUCKET_NAME | tr -d '\r')
SSE_ALGORITHM=$(echo "$BUCKET_ENCRYPTION" | $JQ_CMD -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' | tr -d '\r')
if [[ $SSE_ALGORITHM == "aws:kms" ]]; then
    echo "  ✓ SUCCESS: S3 bucket is encrypted with aws:kms."
else
    echo "  ✗ FAILURE: S3 bucket encryption is not aws:kms. Found: $SSE_ALGORITHM"
    exit 1
fi

# 3. Check DynamoDB Encryption
echo "[CHECK 3] Verifying DynamoDB Encryption on table: $TABLE_NAME..."
TABLE_DESCRIPTION=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL dynamodb describe-table --table-name $TABLE_NAME | tr -d '\r')
SSE_STATUS=$(echo "$TABLE_DESCRIPTION" | $JQ_CMD -r '.Table.SSEDescription.Status' | tr -d '\r')
if [[ $SSE_STATUS == "ENABLED" ]]; then
    echo "  ✓ SUCCESS: DynamoDB table encryption is enabled."
else
    echo "  ✗ FAILURE: DynamoDB encryption is not enabled. Status: $SSE_STATUS"
    exit 1
fi

# 4. Check IAM Policy for Wildcard Actions
echo "[CHECK 4] Verifying IAM policy for wildcard actions..."
POLICY_VERSION=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL iam get-policy --policy-arn $POLICY_ARN | $JQ_CMD -r .Policy.DefaultVersionId | tr -d '\r')
POLICY_DOC=$($AWS_CMD --endpoint-url=$AWS_ENDPOINT_URL iam get-policy-version --policy-arn $POLICY_ARN --version-id $POLICY_VERSION | tr -d '\r')

# Extract actions, handling both single string and array of strings
WILDCARD_ACTIONS=$(echo "$POLICY_DOC" | $JQ_CMD -r '.PolicyVersion.Document.Statement[].Action | if type == "array" then .[] else . end | select(contains("*"))' | tr -d '\r' || true)

# Filter out the acceptable CloudWatch wildcard
ALLOWED_WILDCARD="logs:*"
# Use grep -v to filter out ALLOWED_WILDCARD, if there's any other wildcard it's a failure
if [ -n "$WILDCARD_ACTIONS" ]; then
    FILTERED_WILDCARDS=$(echo "$WILDCARD_ACTIONS" | grep -v "$ALLOWED_WILDCARD" || true)
else
    FILTERED_WILDCARDS=""
fi

if [[ -z "$FILTERED_WILDCARDS" ]]; then
    echo "  ✓ SUCCESS: No forbidden wildcard actions found in IAM policy."
else
    echo "  ✗ FAILURE: Forbidden wildcard actions found: $FILTERED_WILDCARDS"
    exit 1
fi

echo "--- All Compliance Checks Passed! ---"
