"""
process_payment.py — Lambda handler for processing payment events.

Triggered by S3 ObjectCreated events. Reads the payment JSON from S3,
parses the payload, and writes a transaction record to DynamoDB.
"""

import json
import logging
import os
import urllib.parse
from datetime import datetime, timezone
from decimal import Decimal

import boto3

# Configure structured logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# AWS Client Initialization
# ---------------------------------------------------------------------------
localstack_hostname = os.environ.get('LOCALSTACK_HOSTNAME')
edge_port = os.environ.get('EDGE_PORT')

if localstack_hostname and edge_port:
    endpoint_url = f"http://{localstack_hostname}:{edge_port}"
    dynamodb = boto3.resource('dynamodb', endpoint_url=endpoint_url)
    s3_client = boto3.client('s3', endpoint_url=endpoint_url)
    logger.info("Running in LocalStack mode. Endpoint: %s", endpoint_url)
else:
    dynamodb = boto3.resource('dynamodb')
    s3_client = boto3.client('s3')
    logger.info("Running in AWS production mode.")

table = dynamodb.Table(os.environ['DYNAMODB_TABLE_NAME'])


def handler(event, context):
    """
    Lambda entry point. Processes S3 event records and writes transactions
    to DynamoDB.

    Args:
        event: S3 event notification payload containing Records[].
        context: Lambda runtime context object.

    Returns:
        dict with 'status' key indicating success or partial failure.
    """
    logger.info("Received event: %s", json.dumps(event))
    processed = 0
    errors = 0

    for record in event.get('Records', []):
        bucket = record['s3']['bucket']['name']
        # URL-decode the S3 key to handle keys with spaces/special characters
        key = urllib.parse.unquote_plus(record['s3']['object']['key'])

        # --- Read payment data from S3 ---
        try:
            response = s3_client.get_object(Bucket=bucket, Key=key)
            file_content = response['Body'].read().decode('utf-8')
            logger.info("Retrieved object '%s' from bucket '%s'", key, bucket)
            payment_data = json.loads(file_content, parse_float=Decimal)
            amount = payment_data.get('amount', Decimal('0'))
            payment_id = payment_data.get('paymentId', 'N/A')
        except Exception as e:
            logger.error("Failed to read/parse object '%s' from '%s': %s", key, bucket, e)
            amount = Decimal('0')
            payment_id = 'N/A'

        # --- Write transaction record to DynamoDB ---
        now = datetime.now(timezone.utc)
        transaction_id = f"{key}-{now.isoformat()}"

        try:
            table.put_item(
                Item={
                    'TransactionID': transaction_id,
                    'Bucket': bucket,
                    'ObjectKey': key,
                    'PaymentID': payment_id,
                    'Amount': amount,
                    'Status': 'PROCESSED',
                    'Timestamp': now.isoformat()
                }
            )
            logger.info("Written transaction '%s' to DynamoDB", transaction_id)
            processed += 1
        except Exception as e:
            logger.error("Failed to write transaction for '%s': %s", key, e)
            errors += 1

    status = 'success' if errors == 0 else 'partial_failure'
    logger.info("Processing complete. Processed: %d, Errors: %d", processed, errors)
    return {'status': status, 'processed': processed, 'errors': errors}
