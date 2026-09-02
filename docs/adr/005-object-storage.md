# ADR-005: Optional S3 primary storage, provisioned with Terraform

**Status:** Accepted · 2026-09-02

## Context

Nextcloud stores file *content* on a filesystem by default and metadata in the
database. That filesystem is a shared mutable volume, and it is the single
constraint preventing horizontal scaling: every Nextcloud instance must see
every file, immediately.

Nextcloud also supports S3-compatible object storage as *primary storage*,
where content moves to a bucket and only metadata stays in the database.

## Decision

Object storage is **supported and off by default**, configured by
`OBJECTSTORE_S3_*` in `.env`, with Terraform to provision the buckets and IAM.

Terraform rather than Ansible here — the reverse of the Odoo project in this
portfolio — because this project's infrastructure need is storage rather than
host configuration.

## Why it is off by default

**Enabling it on an instance with existing data is not a configuration
change.** Nextcloud does not migrate files when `objectstore` is set: it
begins treating the bucket as the backend, and files already on the local
volume become invisible.

Doing this after the first upload means exporting, reconfiguring and
re-importing — a real migration with downtime. Making it a default would set
that trap for anyone who enabled it later.

## What it changes about backups

With S3 as primary storage, `scripts/backup.sh` no longer captures file
content — only the database and configuration. **The script detects this and
warns**, rather than writing an archive that looks complete and restores an
instance with no user files.

The bucket then needs its own protection. Terraform provides versioning and
lifecycle rules; the IAM policy denies `s3:DeleteObjectVersion` to the
application so a compromised web tier cannot bypass the recovery window.

Bucket versioning is **not** a backup on its own: it protects against
overwrite and deletion, not against the account being compromised.
Cross-account replication is the answer to that and is out of scope.

## The IAM split

Two identities, not one:

- the **application** may read, write and delete objects in primary storage,
  but is explicitly denied deleting *versions*
- the **backup** process may write and read backups, and is denied deletion
  entirely — retention is enforced by the lifecycle rule, not by the host

One shared credential would mean a compromised web application could also
destroy the backups protecting it, which is precisely the scenario backups
exist for.

## A network consequence worth stating

With S3 enabled, the `app` container needs outbound HTTPS. It is already on
the `frontend` network for the app store, federation and SMTP, so nothing
changes — but if that were ever tightened to internal-only, object storage
would break, and the failure would look like a storage fault rather than a
network policy.

## Alternatives considered

**NFS or EFS.** Works unchanged and needs no Nextcloud configuration.
Rejected as the primary recommendation: it adds latency to every file read and
another failure mode, and it does not make the HTTP tier stateless — the
constraint is still a shared mutable filesystem, just a remoter one.

**External storage** (mounting a bucket as a folder inside Nextcloud).
A different feature solving a different problem: it exposes a bucket *to*
users, rather than changing where Nextcloud keeps its own data.

**Terraform for the host as well.** Rejected: there is one host, and Terraform
earns its state file when there is infrastructure to describe.

## Consequences

- **Not applied.** There is no AWS account behind this repository, and saying
  otherwise would be a fabrication. `fmt`, `init -backend=false` and
  `validate` pass and run in CI; that proves the configuration is well-formed,
  not that it creates working infrastructure.
- Latency per file operation increases. Nextcloud handles this, but a
  local-disk instance will feel faster for small files.
- The lifecycle expiry variable must exceed the longest retention in `.env`,
  or it silently deletes backups the retention policy believes it is keeping.
  The variable's description says so.
