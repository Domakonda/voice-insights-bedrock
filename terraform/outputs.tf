output "input_bucket" {
  description = "Upload audio files here to trigger the pipeline"
  value       = aws_s3_bucket.input.bucket
}

output "output_bucket" {
  description = "Bedrock Data Automation writes results here"
  value       = aws_s3_bucket.output.bucket
}

output "transcripts_table" {
  description = "DynamoDB table holding normalized transcripts"
  value       = aws_dynamodb_table.transcripts.name
}

output "api_endpoint" {
  description = "Base URL of the retrieval API (GET /transcripts/{jobId})"
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "submission_queue_url" {
  value = aws_sqs_queue.submission.url
}

output "normalization_queue_url" {
  value = aws_sqs_queue.normalization.url
}
