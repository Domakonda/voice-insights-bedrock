data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  name_base  = "${var.project_name}-${var.environment}"
  suffix     = random_id.suffix.hex

  input_bucket_name  = "${local.name_base}-input-${local.suffix}"
  output_bucket_name = "${local.name_base}-output-${local.suffix}"
  transcripts_table  = "${local.name_base}-transcripts"

  dist_dir = "${path.module}/dist"
}
