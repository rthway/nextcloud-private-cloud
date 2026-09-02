# Object storage with Terraform

Ansible is not used in this repository. This project's infrastructure need is
not host configuration -- it is *storage*, which is the thing Nextcloud
actually runs out of. The Odoo project in this portfolio uses Ansible for the
opposite reason: it needs a hardened host and has no cloud resources to
describe. The reasoning is in
[../../docs/adr/005-object-storage.md](../../docs/adr/005-object-storage.md).

What this creates:

```
  primary storage bucket      Nextcloud writes file CONTENT here.
        |                     Metadata stays in MariaDB.
        |                     Versioned, encrypted, private.
        |
  backup bucket               Backups replicated off-host, with lifecycle
        |                     rules moving older copies to colder storage.
        |
  IAM user + policy           Scoped to exactly these two buckets and nothing
                              else, with separate credentials for each role.
```

## Verification status

**This has never been applied.** There is no AWS account behind this
repository, and claiming otherwise would be a fabrication.

What HAS been done: `terraform fmt -check`, `terraform init -backend=false`
and `terraform validate` pass, and both run in CI on every push. That proves
the configuration is well-formed and internally consistent. It does not prove
it creates working infrastructure.

Treat it as a reviewed starting point. Run `terraform plan` against a
throwaway account and read the output before applying it anywhere real.

## Usage

```bash
cd infrastructure/terraform

cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

terraform init
terraform plan      # read this properly -- it is the last cheap step
terraform apply

terraform output -raw nextcloud_access_key_id
terraform output -raw nextcloud_secret_access_key   # sensitive
```

Then set the outputs in `.env` and recreate the app container.

## The migration problem

**Switching an existing instance to object storage is not a configuration
change.** Nextcloud does not migrate existing files when `objectstore` is
enabled: it starts treating the bucket as the storage backend, and files
already on the local volume become invisible.

Doing this on an instance with data means exporting, reconfiguring and
re-importing — a real migration with downtime. Decide before the first upload,
or plan for it properly. See
[../../docs/adr/005-object-storage.md](../../docs/adr/005-object-storage.md).

## What object storage changes about backups

With S3 as primary storage, `scripts/backup.sh` no longer captures file
content — only the database and configuration. The script detects this and
says so rather than writing an archive that looks complete.

The bucket then needs its own protection, which is what versioning plus
lifecycle rules here provide. Bucket versioning is not a backup on its own: it
protects against overwrite and deletion, not against the account itself being
compromised. Cross-account replication is the answer to that and is out of
scope here.
