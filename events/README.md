# Sample event payloads

Test payloads for invoking each Lambda directly via `aws lambda invoke` or the Lambda console.

| File | Target Lambda | Trigger shape it simulates |
|------|---------------|---------------------------|
| `sample-submission-sqs.json` | submission | Production: S3 ObjectCreated → SQS → Lambda |
| `sample-submission-s3-direct.json` | submission | S3 retry / direct push (no SQS) |
| `sample-submission-shorthand.json` | submission | CLI debug: `{ bucket, key }` |
| `sample-normalization-sqs.json` | normalization | Production: S3 → SQS → Lambda after BDA writes output |
| `sample-normalization-shorthand.json` | normalization | CLI debug |
| `sample-retrieval-apigw.json` | retrieval | API Gateway HTTP API v2 event |
| `sample-bda-result.json` | (data) | Drop into the output bucket to simulate a finished BDA job |

## Invoke from the CLI

```bash
# Pick a function name from `terraform output`, then:

aws lambda invoke \
  --function-name voice-insights-dev-submission \
  --cli-binary-format raw-in-base64-out \
  --payload file://events/sample-submission-shorthand.json \
  out.json && cat out.json

aws lambda invoke \
  --function-name voice-insights-dev-normalization \
  --cli-binary-format raw-in-base64-out \
  --payload file://events/sample-normalization-shorthand.json \
  out.json && cat out.json

aws lambda invoke \
  --function-name voice-insights-dev-retrieval \
  --cli-binary-format raw-in-base64-out \
  --payload file://events/sample-retrieval-apigw.json \
  out.json && cat out.json
```

## End-to-end with real audio

```bash
INPUT=$(terraform -chdir=terraform output -raw input_bucket)
OUTPUT=$(terraform -chdir=terraform output -raw output_bucket)
API=$(terraform -chdir=terraform output -raw api_endpoint)

# 1. Upload a short audio clip
aws s3 cp ./my-clip.mp3 s3://$INPUT/samples/my-clip.mp3

# 2. Watch the BDA job land in the output bucket (usually 20–60s)
aws s3 ls s3://$OUTPUT/transcripts/ --recursive

# 3. Find the jobId from CloudWatch logs of the submission Lambda
aws logs tail /aws/lambda/voice-insights-dev-submission --since 5m

# 4. Fetch the normalized transcript
curl "$API/transcripts/<jobId>"
```

## Simulate normalization without running BDA

Drop the canned BDA output into the output bucket and the normalization
Lambda will fire automatically:

```bash
OUTPUT=$(terraform -chdir=terraform output -raw output_bucket)
aws s3 cp events/sample-bda-result.json \
  s3://$OUTPUT/transcripts/sample-job-1/0/standard_output/0/result.json
```
