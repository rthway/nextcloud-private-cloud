variable "aws_region" {
  description = "Region for the buckets. Put them in the same region as the Nextcloud host: cross-region requests add latency to every file read, and Nextcloud reads a lot of small files."
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Prefix for resource names and tags."
  type        = string
  default     = "nextcloud"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.project_name))
    error_message = "project_name must be 3-32 characters of lowercase letters, digits and hyphens -- it becomes part of an S3 bucket name."
  }
}

variable "environment" {
  description = "Environment name, used in tags and bucket names."
  type        = string
  default     = "prod"
}

variable "bucket_suffix" {
  description = "Suffix making bucket names globally unique. Leave empty to generate a random one -- S3 bucket names are a global namespace, so an unqualified name will collide."
  type        = string
  default     = ""
}

variable "enable_primary_storage_bucket" {
  description = "Create the bucket Nextcloud uses as primary storage. Set false if you only want the backup bucket."
  type        = bool
  default     = true
}

variable "noncurrent_version_retention_days" {
  description = "How long superseded object versions are kept. This is the window in which an accidental overwrite or deletion can be undone, and it is the main reason versioning is on."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_retention_days >= 7
    error_message = "Below 7 days the versioning window is too short to survive a weekend, which is when this protection is most often needed."
  }
}

variable "backup_transition_days" {
  description = "Days before a backup object moves to infrequent-access storage. Backups are written once and read rarely, which is exactly what that tier is for."
  type        = number
  default     = 30
}

variable "backup_glacier_days" {
  description = "Days before a backup object moves to Glacier Instant Retrieval. Beyond this age a backup is a compliance artefact rather than an operational one."
  type        = number
  default     = 90
}

variable "backup_expiration_days" {
  description = "Days before a backup object is deleted. Must exceed the longest retention in .env (BACKUP_RETENTION_MONTHLY x ~30) or the lifecycle rule silently undoes the retention policy."
  type        = number
  default     = 365
}

variable "force_destroy_buckets" {
  description = "Allow `terraform destroy` to delete non-empty buckets. FALSE by default and should stay false: with primary storage in the bucket, true means a stray destroy deletes every user's files with no undo."
  type        = bool
  default     = false
}
