variable "use_localstack" {
  type        = bool
  default     = true
  description = "Whether to use LocalStack for local cloud emulation. Set to false to target actual AWS."
}

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "The AWS region to deploy the resources in."
}
