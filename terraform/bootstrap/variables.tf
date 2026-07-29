variable "project" {
  description = "Must match the main stack's project variable."
  type        = string
  default     = "personal-site"
}

variable "aws_region" {
  description = "Region for the state bucket. Keep this the same as the backend config's region."
  type        = string
  default     = "us-east-1"
}
