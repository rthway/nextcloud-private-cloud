# ---------------------------------------------------------------------------
# Object storage for Nextcloud.
#
# Two buckets with genuinely different requirements:
#
#   primary storage   read and written on every request. Latency matters.
#                     Versioned so an accidental overwrite is recoverable.
#                     NEVER lifecycle-expired -- these are live user files.
#
#   backups           written once, read almost never. Lifecycle rules move
#                     objects to colder tiers and eventually delete them.
#
# Applying one bucket's policy to the other is a serious mistake in either
# direction: lifecycle-expiring primary storage deletes user files, and
# versioning backups without expiry grows the bill forever.
# ---------------------------------------------------------------------------

locals {
  # S3 bucket names are a GLOBAL namespace, so an unqualified name collides
  # with someone else's the first time it is applied.
  suffix = var.bucket_suffix != "" ? var.bucket_suffix : random_id.suffix.hex

  primary_bucket_name = "${var.project_name}-${var.environment}-data-${local.suffix}"
  backup_bucket_name  = "${var.project_name}-${var.environment}-backup-${local.suffix}"
}

resource "random_id" "suffix" {
  byte_length = 4
}

# ---------------------------------------------------------------------------
# Primary storage
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "primary" {
  count = var.enable_primary_storage_bucket ? 1 : 0

  bucket = local.primary_bucket_name

  # Defaults to false. With primary storage here, `terraform destroy` with
  # force_destroy = true deletes every user's files and there is no undo.
  force_destroy = var.force_destroy_buckets

  tags = {
    Name    = local.primary_bucket_name
    Purpose = "nextcloud-primary-storage"
    # Deliberate marker: this bucket holds live data, not backups. Anyone
    # writing a cleanup script should see it.
    DataClass = "user-data"
  }
}

# Public access blocked at every level. Nextcloud generates its own share
# links through the application; nothing here should ever be reachable
# directly, and a public bucket of user files is the worst outcome available.
resource "aws_s3_bucket_public_access_block" "primary" {
  count = var.enable_primary_storage_bucket ? 1 : 0

  bucket = aws_s3_bucket.primary[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning is the recovery mechanism for primary storage. Because Nextcloud
# writes file content here rather than to a volume, `scripts/backup.sh` does
# NOT capture it -- versioning plus the lifecycle rule below is what replaces
# that protection.
#
# It protects against overwrite and deletion. It does not protect against the
# account being compromised; that needs cross-account replication.
resource "aws_s3_bucket_versioning" "primary" {
  count = var.enable_primary_storage_bucket ? 1 : 0

  bucket = aws_s3_bucket.primary[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 here, customer-managed KMS on the backup bucket below. The difference
# is request volume, and the split is deliberate rather than an oversight.
#
# Nextcloud makes an S3 request per file operation. KMS charges per request, so
# on a busy instance the KMS bill for primary storage can exceed the storage
# bill itself. Backups are written once a night: the request cost is negligible
# and a customer-managed key buys exactly what you want protecting the last
# copy of the data -- separate access control, rotation, and revocation by
# disabling the key.
#
# trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "primary" {
  count = var.enable_primary_storage_bucket ? 1 : 0

  bucket = aws_s3_bucket.primary[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# NOTE: there is deliberately NO expiration rule on current versions here.
# These are live user files. Only superseded versions expire.
resource "aws_s3_bucket_lifecycle_configuration" "primary" {
  count = var.enable_primary_storage_bucket ? 1 : 0

  bucket = aws_s3_bucket.primary[0].id

  depends_on = [aws_s3_bucket_versioning.primary]

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    # Nextcloud's chunked upload assembles large files from parts. An
    # interrupted upload leaves those parts billable and invisible in the
    # console until someone goes looking.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "backup" {
  bucket        = local.backup_bucket_name
  force_destroy = var.force_destroy_buckets

  tags = {
    Name      = local.backup_bucket_name
    Purpose   = "nextcloud-backups"
    DataClass = "backup"
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

# A customer-managed KMS key for backups.
#
# This is what makes access to the last copy of the data revocable
# independently of IAM: disabling the key makes every object unreadable
# immediately, without editing a single policy.
resource "aws_kms_key" "backup" {
  description             = "${var.project_name}-${var.environment} Nextcloud backup encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name = "${var.project_name}-${var.environment}-backup"
  }
}

resource "aws_kms_alias" "backup" {
  name          = "alias/${var.project_name}-${var.environment}-backup"
  target_key_id = aws_kms_key.backup.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.backup.arn
    }
    # Bucket keys cut KMS request volume substantially, by deriving a
    # short-lived key per bucket rather than calling KMS for every object.
    bucket_key_enabled = true
  }
}

# Backups are written once and read almost never, which is exactly the access
# pattern the colder tiers are priced for.
#
# expiration MUST exceed the longest retention in .env
# (BACKUP_RETENTION_MONTHLY x ~30 days) or this rule silently deletes backups
# the retention policy believes it is keeping -- and nothing reports that until
# someone needs one of them.
resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  depends_on = [aws_s3_bucket_versioning.backup]

  rule {
    id     = "tier-and-expire-backups"
    status = "Enabled"

    filter {}

    transition {
      days          = var.backup_transition_days
      storage_class = "STANDARD_IA"
    }

    transition {
      days = var.backup_glacier_days
      # Instant Retrieval rather than Flexible or Deep Archive: a backup that
      # takes hours to retrieve is not a backup you can restore from during an
      # incident. The storage saving is smaller and the difference matters at
      # exactly the wrong moment.
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = var.backup_expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Object Lock cannot be enabled on an existing bucket, so this is a note
# rather than a resource: for genuine ransomware protection, create the backup
# bucket with object_lock_enabled = true and a COMPLIANCE-mode retention
# period. That makes backups undeletable even by the account root, which is
# the point -- and also means a misconfigured retention cannot be undone, so
# it is a decision to make deliberately rather than a default.

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------
# Two identities rather than one. The Nextcloud application needs read and
# write on primary storage; the backup process needs write on backups. Sharing
# one credential means a compromised web application can also destroy the
# backups protecting it -- which is precisely the scenario backups exist for.

resource "aws_iam_user" "nextcloud" {
  count = var.enable_primary_storage_bucket ? 1 : 0

  name = "${var.project_name}-${var.environment}-app"
  path = "/service/"

  tags = {
    Purpose = "nextcloud-primary-storage-access"
  }
}

resource "aws_iam_user_policy" "nextcloud" {
  count = var.enable_primary_storage_bucket ? 1 : 0

  name = "${var.project_name}-${var.environment}-primary-storage"
  user = aws_iam_user.nextcloud[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListOwnBucket"
        Effect = "Allow"
        Action = ["s3:ListBucket", "s3:GetBucketLocation"]
        # Scoped to this bucket. A wildcard here would let the application
        # enumerate every bucket in the account.
        Resource = [aws_s3_bucket.primary[0].arn]
      },
      {
        Sid    = "ObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = ["${aws_s3_bucket.primary[0].arn}/*"]
      },
      {
        # Nextcloud deletes objects during its own file operations, and
        # versioning means those deletes create delete markers rather than
        # destroying data. Permanently deleting a VERSION is explicitly denied
        # so a compromised application cannot bypass the recovery window that
        # versioning exists to provide.
        Sid      = "DenyPermanentVersionDeletion"
        Effect   = "Deny"
        Action   = ["s3:DeleteObjectVersion"]
        Resource = ["${aws_s3_bucket.primary[0].arn}/*"]
      },
    ]
  })
}

resource "aws_iam_access_key" "nextcloud" {
  count = var.enable_primary_storage_bucket ? 1 : 0
  user  = aws_iam_user.nextcloud[0].name
}

resource "aws_iam_user" "backup" {
  name = "${var.project_name}-${var.environment}-backup"
  path = "/service/"

  tags = {
    Purpose = "nextcloud-backup-upload"
  }
}

resource "aws_iam_user_policy" "backup" {
  name = "${var.project_name}-${var.environment}-backup"
  user = aws_iam_user.backup.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBackupBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.backup.arn]
      },
      {
        # Write and read, but NOT delete. Retention is enforced by the
        # lifecycle rule above, not by the backup process -- so a compromised
        # host cannot delete the backups that would recover it.
        Sid    = "WriteAndReadBackups"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = ["${aws_s3_bucket.backup.arn}/*"]
      },
      {
        Sid      = "DenyAllDeletion"
        Effect   = "Deny"
        Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = ["${aws_s3_bucket.backup.arn}/*"]
      },
      {
        # Required to write to and read from a KMS-encrypted bucket. Scoped to
        # this one key rather than kms:* across the account.
        #
        # Note what is NOT granted: kms:ScheduleKeyDeletion and kms:DisableKey.
        # A compromised backup host must not be able to make every existing
        # backup unreadable, which is a quieter way to destroy them than
        # deleting the objects.
        Sid    = "UseBackupKey"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = [aws_kms_key.backup.arn]
      },
    ]
  })
}

resource "aws_iam_access_key" "backup" {
  user = aws_iam_user.backup.name
}
