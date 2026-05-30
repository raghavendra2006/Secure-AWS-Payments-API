from decimal import Decimal
import json
import boto3
import os
from datetime import datetime

# Initialize DynamoDB resource and S3 client.
# In LocalStack, endpoint_url must be specified.
localstack_hostname = os.environ.get('LOCALSTACK_HOSTNAME')
edge_port = os.environ.get('EDGE_PORT')

if localstack_hostname and edge_port:
    endpoint_url = f"http://{localstack_hostname}:{edge_port}"
    dynamodb = boto3.resource('dynamodb', endpoint_url=endpoint_url)
    s3_client = boto3.client('s3', endpoint_url=endpoint_url)
    print(f"Running in LocalStack mode. Using endpoint: {endpoint_url}")
else:
    dynamodb = boto3.resource('dynamodb')
    s3_client = boto3.client('s3')
    print("Running in AWS production/cloud mode.")

table = dynamodb.Table(os.environ['DYNAMODB_TABLE_NAME'])

def handler(event, context):
    print("Received event:", json.dumps(event))
    for record in event['Records']:
        bucket = record['s3']['bucket']['name']
        key = record['s3']['object']['key']
        
        # Call the S3 GetObject API to retrieve the payment event file
        try:
            response = s3_client.get_object(Bucket=bucket, Key=key)
            file_content = response['Body'].read().decode('utf-8')
            print(f"Retrieved file content from S3: {file_content}")
            payment_data = json.loads(file_content, parse_float=Decimal)
            amount = payment_data.get('amount', Decimal('0'))
            payment_id = payment_data.get('paymentId', 'N/A')
        except Exception as e:
            print(f"Error reading object {key} from S3 bucket {bucket}: {e}")
            amount = Decimal('0')
            payment_id = 'N/A'

        # Create a transaction ID from the key and current time
        transaction_id = f"{key}-{datetime.utcnow().isoformat()}"

        # Write to DynamoDB
        table.put_item(
            Item={
                'TransactionID': transaction_id,
                'Bucket': bucket,
                'ObjectKey': key,
                'PaymentID': payment_id,
                'Amount': amount,
                'Status': 'PROCESSED',
                'Timestamp': datetime.utcnow().isoformat()
            }
        )
        print(f"Processed {key} from {bucket}. TransactionID: {transaction_id}")
    return {'status': 'success'}
