# Runbook: backup failed or cannot be verified

**Surfaced by:** the exit code of `scripts/backup.sh` and
`scripts/verify-backup.sh`, and the Backups section of `make health`.
**Severity:** urgent. Every hour without a good backup widens the window of
data you cannot get back.

---

## First: check the instance is not stuck offline

`backup.sh` puts Nextcloud into maintenance mode so the database dump and the
file archive describe the same instant. It clears that in a trap on exit — but
a process killed with SIGKILL never runs its trap.

**So the first consequence of a failed backup is often an outage:**

```bash
./scripts/occ.sh status
```

If `maintenance: true` and no backup is running:

```bash
./scripts/occ.sh maintenance:mode --off
```

## Then: how exposed are you?

```bash
make backups
```

The age of the newest **verified** backup is your current worst-case data
loss. State that number when reporting the incident — it is what people
actually need.

---

## Diagnosis

`backup.sh` removes a partial backup on failure rather than leaving something
that looks complete, so a missing directory after a failed run is expected.

| Failure | Meaning | Fix |
|---|---|---|
| `the db service is not running` | nothing to back up | start the stack |
| `Nextcloud does not report itself as installed` | app down, or mid-upgrade | [application-down.md](application-down.md) |
| `could not enter maintenance mode` | occ cannot reach the database | [database-unavailable.md](database-unavailable.md) |
| `mariadb-dump produced an empty file` | dump failed | read `mariadb-dump.log` in the backup directory |
| `dump contains only N/5 core Nextcloud tables` | wrong database, or the dump stopped early | *Incomplete dump* |
| `data archive fails gzip integrity check` | truncated stream | usually disk space |
| `BACKUP_AGE_RECIPIENT is set but 'age' is not installed` | encryption requested, tool missing | install `age`, or clear the variable |

That last case is deliberately fatal. Silently writing an unencrypted backup —
of every user's files — when the operator asked for encryption is a failure
discovered only by whoever finds the backup.

### Verification failures

| Check | Meaning |
|---|---|
| `CHECKSUM MISMATCH` | the artefact changed after it was written |
| `only N tables` | the restore stopped early |
| `config archive does NOT contain config.php` | a restore would have no database credentials |
| `config.php has no passwordsalt` | **a restore would invalidate every user password** |
| `archive is missing files the database references` | database and files are inconsistent |

The `passwordsalt` check deserves emphasis: `instanceid`, `passwordsalt` and
`secret` live in `config.php`, not the database. Restoring a database with a
different `passwordsalt` leaves every stored password hash unverifiable, and
there is no way back except restoring the matching config.

---

## Resolution

### Incomplete dump

```bash
gzip -dc backups/<id>/database.sql.gz | grep -c 'CREATE TABLE'
```

Take a fresh backup and verify it immediately:

```bash
./scripts/backup.sh --no-prune
./scripts/verify-backup.sh
```

**`--no-prune` matters** — do not let a retention pass run while you are
unsure which backups are good.

### Database and files inconsistent

`backup.sh` uses maintenance mode specifically to prevent this, so seeing it
means either `--no-maintenance` was used, or maintenance mode failed to engage
and the run continued.

Take a fresh backup with quiescing and verify it.

### Backups are not running at all

```bash
systemctl list-timers | grep nextcloud
journalctl -u nextcloud-backup.service --since '7 days ago' | tail -30
```

A backup job that has silently stopped is the most dangerous failure here,
because everything looks fine until someone needs a restore. `make health`
checks backup age for exactly that reason.

---

## Verification

A backup is not fixed until it has been proved restorable:

```bash
./scripts/backup.sh
./scripts/verify-backup.sh
```

Exit 0 means it was restored into a throwaway schema and passed every schema,
data and file cross-check. The manifest is updated with `"verified": true`.

---

## Prevention

- Run `verify-backup.sh` on a schedule. It is safe against production — it
  never touches the live database or data directory.
- Keep at least one copy off this host.
- Set `BACKUP_AGE_RECIPIENT`. These archives contain every user's files and
  the database password from `config.php`.
- Alert on backup age. Silence is the failure mode.
