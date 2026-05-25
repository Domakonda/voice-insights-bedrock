resource "aws_sqs_queue" "submission_dlq" {
  name                      = "${local.name_base}-submission-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "submission" {
  name                       = "${local.name_base}-submission"
  visibility_timeout_seconds = var.lambda_timeout_seconds * 6
  message_retention_seconds  = 345600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.submission_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "submission" {
  queue_url = aws_sqs_queue.submission.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowS3Send"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.submission.arn
      Condition = {
        ArnLike     = { "aws:SourceArn" = "arn:${local.partition}:s3:::${local.input_bucket_name}" }
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_sqs_queue" "normalization_dlq" {
  name                      = "${local.name_base}-normalization-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "normalization" {
  name                       = "${local.name_base}-normalization"
  visibility_timeout_seconds = var.lambda_timeout_seconds * 6
  message_retention_seconds  = 345600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.normalization_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "normalization" {
  queue_url = aws_sqs_queue.normalization.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowS3Send"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.normalization.arn
      Condition = {
        ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:s3:::${local.output_bucket_name}" }
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}
