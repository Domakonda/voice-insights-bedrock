resource "aws_s3_bucket" "input" {
  bucket        = local.input_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "input" {
  bucket                  = aws_s3_bucket.input.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "input" {
  bucket = aws_s3_bucket.input.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "input" {
  bucket = aws_s3_bucket.input.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_notification" "input" {
  bucket = aws_s3_bucket.input.id

  queue {
    queue_arn = aws_sqs_queue.submission.arn
    events    = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sqs_queue_policy.submission]
}

resource "aws_s3_bucket" "output" {
  bucket        = local.output_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "output" {
  bucket                  = aws_s3_bucket.output.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "output" {
  bucket = aws_s3_bucket.output.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "output" {
  bucket = aws_s3_bucket.output.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_notification" "output" {
  bucket = aws_s3_bucket.output.id

  queue {
    queue_arn     = aws_sqs_queue.normalization.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = "result.json"
  }

  depends_on = [aws_sqs_queue_policy.normalization]
}
