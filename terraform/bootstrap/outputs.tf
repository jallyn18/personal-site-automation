output "state_bucket" {
  description = "Put this in backend.hcl as the `bucket` value."
  value       = aws_s3_bucket.state.id
}

output "backend_config" {
  description = "Paste into terraform/backend.hcl."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.id}"
    key          = "${var.project}/terraform.tfstate"
    region       = "${var.aws_region}"
    encrypt      = true
    use_lockfile = true
  EOT
}
