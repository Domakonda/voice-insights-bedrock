resource "aws_cloudwatch_log_group" "submission" {
  name              = "/aws/lambda/${local.name_base}-submission"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "submission" {
  function_name    = "${local.name_base}-submission"
  role             = aws_iam_role.submission.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = "${local.dist_dir}/submission.zip"
  source_code_hash = filebase64sha256("${local.dist_dir}/submission.zip")
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = {
      BDA_PROJECT_ARN = var.bda_project_arn
      BDA_PROFILE_ARN = var.bda_profile_arn
      OUTPUT_BUCKET   = aws_s3_bucket.output.bucket
      OUTPUT_PREFIX   = "transcripts"
      LOG_LEVEL       = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.submission]
}

resource "aws_lambda_event_source_mapping" "submission" {
  event_source_arn                   = aws_sqs_queue.submission.arn
  function_name                      = aws_lambda_function.submission.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}

resource "aws_cloudwatch_log_group" "normalization" {
  name              = "/aws/lambda/${local.name_base}-normalization"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "normalization" {
  function_name    = "${local.name_base}-normalization"
  role             = aws_iam_role.normalization.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = "${local.dist_dir}/normalization.zip"
  source_code_hash = filebase64sha256("${local.dist_dir}/normalization.zip")
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds

  environment {
    variables = {
      TRANSCRIPTS_TABLE = aws_dynamodb_table.transcripts.name
      LOG_LEVEL         = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.normalization]
}

resource "aws_lambda_event_source_mapping" "normalization" {
  event_source_arn                   = aws_sqs_queue.normalization.arn
  function_name                      = aws_lambda_function.normalization.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}

resource "aws_cloudwatch_log_group" "retrieval" {
  name              = "/aws/lambda/${local.name_base}-retrieval"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "retrieval" {
  function_name    = "${local.name_base}-retrieval"
  role             = aws_iam_role.retrieval.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = "${local.dist_dir}/retrieval.zip"
  source_code_hash = filebase64sha256("${local.dist_dir}/retrieval.zip")
  memory_size      = var.lambda_memory_mb
  timeout          = 15

  environment {
    variables = {
      TRANSCRIPTS_TABLE = aws_dynamodb_table.transcripts.name
      LOG_LEVEL         = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.retrieval]
}
