variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "voice-insights"
}

variable "environment" {
  description = "Deployment environment (dev | staging | prod)"
  type        = string
  default     = "dev"
}

variable "owner_tag" {
  description = "Value for the Owner tag on all resources"
  type        = string
  default     = "aravind-domakonda"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days"
  type        = number
  default     = 14
}

variable "bda_project_arn" {
  description = "ARN of the Bedrock Data Automation project to invoke. Create via scripts/create-bda-project.sh and pass here."
  type        = string
}

variable "bda_profile_arn" {
  description = "ARN of the Bedrock Data Automation profile (e.g. arn:aws:bedrock:us-east-1:ACCOUNT:data-automation-profile/us.data-automation-v1)"
  type        = string
}

variable "lambda_memory_mb" {
  description = "Default Lambda memory size"
  type        = number
  default     = 512
}

variable "lambda_timeout_seconds" {
  description = "Default Lambda timeout in seconds"
  type        = number
  default     = 60
}
