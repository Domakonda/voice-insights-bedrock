data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Submission Lambda role
resource "aws_iam_role" "submission" {
  name               = "${local.name_base}-submission"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "submission_basic" {
  role       = aws_iam_role.submission.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "submission" {
  statement {
    sid     = "SqsRead"
    effect  = "Allow"
    actions = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.submission.arn]
  }
  statement {
    sid     = "S3ReadInput"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.input.arn}/*"]
  }
  statement {
    sid     = "S3WriteOutput"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.output.arn}/*"]
  }
  statement {
    sid       = "InvokeBDA"
    effect    = "Allow"
    actions   = ["bedrock:InvokeDataAutomationAsync"]
    resources = [var.bda_project_arn, var.bda_profile_arn]
  }
}

resource "aws_iam_role_policy" "submission" {
  role   = aws_iam_role.submission.name
  policy = data.aws_iam_policy_document.submission.json
}

# Normalization Lambda role
resource "aws_iam_role" "normalization" {
  name               = "${local.name_base}-normalization"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "normalization_basic" {
  role       = aws_iam_role.normalization.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "normalization" {
  statement {
    sid     = "SqsRead"
    effect  = "Allow"
    actions = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.normalization.arn]
  }
  statement {
    sid     = "S3ReadOutput"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.output.arn}/*"]
  }
  statement {
    sid     = "DdbWrite"
    effect  = "Allow"
    actions = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.transcripts.arn]
  }
}

resource "aws_iam_role_policy" "normalization" {
  role   = aws_iam_role.normalization.name
  policy = data.aws_iam_policy_document.normalization.json
}

# Retrieval Lambda role
resource "aws_iam_role" "retrieval" {
  name               = "${local.name_base}-retrieval"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "retrieval_basic" {
  role       = aws_iam_role.retrieval.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "retrieval" {
  statement {
    sid     = "DdbRead"
    effect  = "Allow"
    actions = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.transcripts.arn]
  }
}

resource "aws_iam_role_policy" "retrieval" {
  role   = aws_iam_role.retrieval.name
  policy = data.aws_iam_policy_document.retrieval.json
}
