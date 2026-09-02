# Backup and restore

## Three artefacts, not one

| Artefact | Contents | Captured by |
|---|---|---|
| `database.sql.gz` | metadata, users, shares, app state | `mariadb-dump --single-transaction` |
| `data.tar.gz` | the actual file content | `tar` of `/var/www/html/data` |
| `config.tar.gz` | `config.php`, apps, themes | `tar` of `config/ apps/ themes/` |

Missing any one produces a restore that fails in a different way:

- **No data** → an instance whose file listings are populated and whose files
  are all missing.
- **No config** → no database credentials, and worse: `config.php` holds
  `instanceid`, `secret` and **`passwordsalt`**. Restore a database with a
  different `passwordsalt` and **every stored password becomes unverifiable**.
  There is no recovery except restoring the matching config.

`verify-backup.sh` asserts `passwordsalt` and `instanceid` are present in the
archive, because nothing else would catch their absence until the first login
after a restore.

## Quiescing: what makes this different

**Nextcloud can be put into maintenance mode, and this backup does.**

That is a real difference from a pure database application. Nextcloud's
`oc_filecache` holds a row per file with its size, mtime and checksum. If a
file is written between the dump and the file copy, the restored instance has
metadata that does not match the bytes on disk — Nextcloud detects the
mismatch, and the repair is a full `occ files:scan`, which on a large instance
takes hours.

So `backup.sh`:

1. `occ maintenance:mode --on` — the instance stops accepting writes
2. dumps the database, archives config, archives data
3. `occ maintenance:mode --off` **before** checksums and encryption, so the
   outage is only as long as it needs to be

The cost is downtime, typically the dump duration. `--no-maintenance` skips it
and accepts the skew, with a warning that a restore may need `files:scan`.

**A failed backup can therefore leave the instance offline.** The script clears
maintenance mode in a trap on exit — but a process killed with SIGKILL never
runs its trap, which is why `make health` reports maintenance mode loudly and
why the backup runbook checks it first.

## Retention

Grandfather-father-son: 7 daily, 4 weekly, 6 monthly.

"Keep the last N backups" is not a retention policy. Corruption discovered on
Tuesday, after a long weekend of nightly backups, has already overwritten
every copy of the good data.

`prune-backups.sh` always keeps the newest backup unconditionally — a policy
that can delete the last copy has a bug in it.

## Verification

```bash
./scripts/verify-backup.sh          # newest
./scripts/verify-backup.sh <id>     # specific
```

Restores into a throwaway schema **alongside** the live one and checks:

1. **Integrity** — SHA-256 checksums, gzip readability
2. **Config** — `config.php` present, with `passwordsalt` and `instanceid`
3. **Restore** — into `verify_<id>`
4. **Schema** — table count, seven core tables, index count
5. **Data** — users, and that **every user has a non-empty password hash**
   (a restore missing those looks complete and locks everyone out)
6. **Cross-check** — `oc_filecache` rows against files in the archive

Step 6 is what makes it a real verification. On the recorded run: **65
database rows against 65 archived files.**

The live database, data directory and running instance are never touched, so
this is safe against production and intended to be.

## Encryption

Set `BACKUP_AGE_RECIPIENT` to an `age` public key. If it is set and `age` is
missing, **the backup fails** — silently writing an unencrypted archive of
every user's files, plus the database password from `config.php`, is a failure
found only by whoever finds the backup.

Store the private half off-host. An encrypted backup whose key is on the
machine that burned down is not a backup.

## Object storage changes this

With S3 as primary storage, file content is in the bucket, not on the volume.
`backup.sh` detects this and **warns** rather than writing an archive that
looks complete and restores an instance with no user files.

The bucket then needs its own protection: versioning plus lifecycle rules,
which the Terraform provides. Bucket versioning protects against overwrite and
deletion, not against the account being compromised.

## Recovery objectives

| | Target | Basis |
|---|---|---|
| **RPO** | 24 hours | nightly schedule |
| **RTO** | under 1 hour on existing hardware | see [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md) |

**Targets, not achievements.** The only measured figure is a 6-second database
restore of a 131-table schema on the author's laptop. Real recovery time is
dominated by the *file* restore, which scales with how much data users have.

RPO of 24 hours means a day of file changes is lost in a total-loss scenario.

## Restoring

Full procedure: [docs/runbooks/restore-database.md](docs/runbooks/restore-database.md).

```bash
./scripts/verify-backup.sh <id>   # prove it first
./scripts/backup.sh --no-prune    # capture current state, damaged as it is
./scripts/restore.sh <id>
```

**Files are restored before the database**, which is the reverse of the
intuitive order and deliberate — see the runbook.

## Scheduling

Two timers, and the second is the one most schedules omit:

| Timer | When | Purpose |
|---|---|---|
| backup | daily 02:30 | three artefacts, then retention |
| verify | Sunday 04:00 | prove the newest backup restores |

Use `Persistent=true` so a host that was off at the scheduled time runs on
next boot rather than silently skipping.
