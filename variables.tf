variable "use_localstack" {
  type        = bool
  default     = true
  description = "Whether to use LocalStack for local cloud emulation. Set to false to target actual AWS."
}

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "The AWS region to deploy the resources in."

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "Must be a valid AWS region identifier (e.g., us-east-1, eu-west-2)."
  }
}

variable "localstack_endpoint" {
  type        = string
  default     = "http://localhost:4566"
  description = "The endpoint URL for LocalStack services. Only used when use_localstack is true."

  validation {
    condition     = can(regex("^https?://", var.localstack_endpoint))
    error_message = "Must be a valid HTTP(S) URL."
  }
}
