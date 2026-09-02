output "primary_bucket_name" {
  description = "Set as OBJECTSTORE_S3_BUCKET in .env."
  value       = var.enable_primary_storage_bucket ? aws_s3_bucket.primary[0].bucket : null
}

output "backup_bucket_name" {
  description = "Target for off-host backup replication."
  value       = aws_s3_bucket.backup.bucket
}

output "aws_region" {
  description = "Set as OBJECTSTORE_S3_REGION in .env."
  value       = var.aws_region
}

output "nextcloud_access_key_id" {
  description = "Set as OBJECTSTORE_S3_KEY in .env."
  value       = var.enable_primary_storage_bucket ? aws_iam_access_key.nextcloud[0].id : null
}

output "nextcloud_secret_access_key" {
  description = "Set as OBJECTSTORE_S3_SECRET in .env. Retrieve with: terraform output -raw nextcloud_secret_access_key"
  value       = var.enable_primary_storage_bucket ? aws_iam_access_key.nextcloud[0].secret : null

  # Marked sensitive so it is redacted from plan and apply output. Note this
  # does NOT protect the state file, where it is stored in plaintext -- which
  # is why versions.tf insists remote state be encrypted.
  sensitive = true
}

output "backup_access_key_id" {
  description = "Credential for the backup replication step."
  value       = aws_iam_access_key.backup.id
}

output "backup_secret_access_key" {
  description = "Retrieve with: terraform output -raw backup_secret_access_key"
  value       = aws_iam_access_key.backup.secret
  sensitive   = true
}

# The .env fragment, assembled from a list rather than a heredoc.
#
# A `<<-EOT` block cannot be used inside a ternary: its closing marker must sit
# alone on its own line, so the `: "fallback"` half of the conditional leaves
# the string unterminated and Terraform fails to parse the whole file. Building
# a list and joining it sidesteps that entirely and is easier to extend.
locals {
  env_lines = var.enable_primary_storage_bucket ? [
    "OBJECTSTORE_S3_BUCKET=${try(aws_s3_bucket.primary[0].bucket, "")}",
    "OBJECTSTORE_S3_REGION=${var.aws_region}",
    "OBJECTSTORE_S3_HOST=s3.${var.aws_region}.amazonaws.com",
    "OBJECTSTORE_S3_SSL=true",
    "OBJECTSTORE_S3_USEPATH_STYLE=false",
    "OBJECTSTORE_S3_KEY=<terraform output -raw nextcloud_access_key_id>",
    "OBJECTSTORE_S3_SECRET=<terraform output -raw nextcloud_secret_access_key>",
  ] : ["# object storage is disabled (enable_primary_storage_bucket = false)"]
}

output "env_snippet" {
  description = "Paste into .env. The two secrets are deliberately shown as placeholders rather than values, so they do not land in a shell history file, a CI log, or a screenshot."
  value       = join("\n", local.env_lines)
}
