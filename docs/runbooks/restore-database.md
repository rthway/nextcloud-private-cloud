# Runbook: restoring Nextcloud

**Use when:** data has been lost or corrupted, an upgrade has failed, or you
need production data to investigate.
**Severity:** the default path is destructive — read before running.

---

## Decide which operation you are doing

| Goal | Command | Touches live data? |
|---|---|---|
| Prove a backup is good | `./scripts/verify-backup.sh <id>` | No |
| Recover after data loss | `./scripts/restore.sh <id>` | **Yes — destroys the current database and data directory** |

If unsure, start with `verify-backup.sh`. It answers "is this backup good"
while risking nothing.

---

## Before a destructive restore

### 1. Capture the current state, damaged as it is

It may contain data written after the backup you are about to restore.

```bash
./scripts/backup.sh --no-prune
```

If Nextcloud is too broken for that, take the volumes directly:

```bash
docker run --rm -v nextcloud_db-data:/data:ro -v "$PWD/backups:/out" \
  alpine tar -czf /out/pre-restore-db-$(date -u +%Y%m%dT%H%M%SZ).tar.gz -C /data .
docker run --rm -v nextcloud_nextcloud-data:/data:ro -v "$PWD/backups:/out" \
  alpine tar -czf /out/pre-restore-files-$(date -u +%Y%m%dT%H%M%SZ).tar.gz -C /data .
```

### 2. Verify the backup you intend to restore

```bash
./scripts/verify-backup.sh <backup-id>
```

`restore.sh` checks checksums before dropping anything, for this reason —
discovering a corrupt archive after destroying the live data converts a
recoverable incident into an unrecoverable one.

### 3. Check the version

Nextcloud has **no downgrade path**. Restoring a database written by a newer
version into older code fails at the schema check — after the live database
is already gone.

`restore.sh` compares the backup's version against the running instance and
warns. If the backup is newer, pin `NEXTCLOUD_VERSION` in `.env` to match
before restoring.

### 4. Know your data loss window

Everything between the backup timestamp and now will be gone. State that
plainly to whoever is affected **before** you start.

---

## Restoring

```bash
./scripts/restore.sh 20260902T054616Z
```

What it does, and why the order is what it is:

1. verifies checksums, refusing to continue on a mismatch
2. requires you to type the **database name** — not `y`, because a
   muscle-memory `y` is how the right backup reaches the wrong environment
3. stops **both** app and cron. Leaving cron running means background jobs
   operating against a half-restored database, and a file scan in that state
   marks real files as deleted
4. **restores files BEFORE the database.** The reverse order leaves a window
   where Nextcloud runs against metadata for files not yet on disk; anything
   touching it then marks them deleted
5. fixes ownership to `www-data` — files extracted as root cannot be read by
   the FPM workers, and the symptom is an instance that starts and shows an
   empty file list
6. drops and recreates the database, restores, and validates table and row
   counts
7. restarts and clears maintenance mode

Add `--yes` to skip the prompt in an automated recovery.

---

## After the restore

**1. Log in.** `status.php` returning 200 says PHP answered; it does not say
the application is coherent.

**2. Open a file.** This is the only check that catches a database restored
without its data directory, and nothing else will catch it — the UI looks
entirely healthy until someone clicks a document.

**3. If the versions differed:**

```bash
./scripts/occ.sh upgrade
```

**4. If anything looks inconsistent:**

```bash
./scripts/occ.sh files:scan --all
```

This reconciles `oc_filecache` with what is actually on disk. On a large
instance it takes hours, which is why it is not run automatically.

**5. In a non-production restore, neutralise outbound activity before anyone
notices** — otherwise a restored copy starts emailing real users about real
shares:

```bash
./scripts/occ.sh config:system:set mail_smtpmode --value ""
./scripts/occ.sh background:cron    # then stop the cron container
docker compose stop cron
```

---

## Verification

```bash
make health
```

And directly:

```bash
set -a; source .env; set +a
docker compose exec -e MYSQL_PWD="$MYSQL_PASSWORD" -T db \
  mariadb -u "$MYSQL_USER" "$MYSQL_DATABASE" -e "
    SELECT (SELECT COUNT(*) FROM oc_users)     AS users,
           (SELECT COUNT(*) FROM oc_filecache) AS files,
           (SELECT COUNT(*) FROM oc_share)     AS shares;"
```

Compare against the manifest and against what the business expects.

---

## If the restore fails

- **Do not re-run it blindly.** The database is now in a partial state.
- Read `backups/<id>/restore-*.log`.
- Try an older backup — `make backups` lists which have been verified.
- The pre-restore copy from step 1 is the fallback. This is where that step
  pays for itself.

Escalate rather than improvising. See
[../../DISASTER-RECOVERY.md](../../DISASTER-RECOVERY.md).
