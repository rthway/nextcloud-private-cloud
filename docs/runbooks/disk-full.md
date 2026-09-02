# Runbook: disk full or filling

**Alerts:** `DiskSpaceLow`, `DiskSpaceCritical`, `DiskWillFillIn24Hours`
**Severity:** critical below 10% free

---

## Why this is the runbook you will use most

This is a file-sync server. Its entire purpose is accumulating data, so disk
pressure is not an anomaly — it is the steady state, and the only question is
whether anything is reclaiming space.

MariaDB stops accepting writes when it cannot extend a tablespace or the
binlog. `DiskWillFillIn24Hours` is the alert to act on: it fires on the trend,
which buys working hours instead of 3am.

## Symptoms

- Uploads fail, or the web UI reports "Not enough free space".
- MariaDB logs `Disk is full writing`.
- `No space left on device` in any container log.

---

## Diagnosis

### 1. Where has it gone?

```bash
df -h
docker system df -v | head -30
```

### 2. Which volume?

```bash
docker compose exec -T app df -h /var/www/html/data
docker compose exec -T db  df -h /var/lib/mysql
du -sh backups/ 2>/dev/null
```

In rough order of likelihood on this stack:

| Consumer | Why it grows | Section |
|---|---|---|
| Trash and file versions | **background jobs stopped** | *Trash and versions* |
| `backups/` | retention not running | *Backups* |
| User files | genuine growth | *Quotas* |
| Previews | large image libraries | *Previews* |
| MariaDB binlog | 7-day retention, or a stuck purge | *Binlog* |
| Docker build cache | accumulates silently | *Docker* |

---

## Resolution

Safest first.

### Trash and versions — usually the biggest win

**Check whether background jobs are running before anything else.** If they
have stopped, trash has never expired and this is the real cause:

```bash
./scripts/occ.sh config:app:get core lastcron
```

If stale, fix that first — [cron-not-running.md](cron-not-running.md) — then:

```bash
./scripts/occ.sh trashbin:expire
./scripts/occ.sh versions:expire
```

Both can take a long time on a neglected instance. Retention is set in
`zz-managed.config.php`: trash 30 days, versions 90.

### Backups

```bash
./scripts/prune-backups.sh --dry-run
./scripts/prune-backups.sh
```

Grandfather-father-son retention always keeps the newest backup, so this
cannot remove your last copy.

**Backups on the same volume as the data they protect is a self-inflicted
outage.** Move them off-host.

### Previews

```bash
docker compose exec -T app du -sh /var/www/html/data/appdata_*/preview 2>/dev/null
```

Previews are regenerable. Deleting them frees space immediately at the cost of
regenerating on next view:

```bash
./scripts/occ.sh maintenance:mode --on
docker compose exec --user www-data -T app sh -c 'rm -rf /var/www/html/data/appdata_*/preview/*'
./scripts/occ.sh maintenance:mode --off
./scripts/occ.sh files:scan-app-data
```

### Quotas

Unlimited quota means one user can fill the disk for everyone:

```bash
./scripts/occ.sh user:list
./scripts/occ.sh user:setting <user> files quota "10 GB"
```

`NEXTCLOUD_DEFAULT_QUOTA` sets the default for new accounts.

### Binlog

```bash
docker compose exec -T db du -sh /var/lib/mysql/binlog.*  2>/dev/null | tail -3
```

`--expire-logs-days=7` is set in `compose.yml`. To purge sooner:

```bash
set -a; source .env; set +a
```

```bash
docker compose exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" -T db mariadb -u root -e "
  PURGE BINARY LOGS BEFORE DATE_SUB(NOW(), INTERVAL 2 DAY);"
```

Only purge logs no replica or point-in-time restore still needs.

### Docker

```bash
docker builder prune -af
docker image prune -f
```

**Do not run `docker system prune --volumes`** — "unused" includes the
database volume of any stopped stack.

---

## If MariaDB has already stopped

1. Free space by the means above. Delete nothing from `/var/lib/mysql`.
2. Restart and let InnoDB recovery finish:
   ```bash
   docker compose restart db
   docker compose logs -f db      # wait for "ready for connections"
   ```

---

## Verification

```bash
df -h
make health
```

Then upload a file through the web UI — that is the check that matters.

---

## Prevention

- Act on `DiskWillFillIn24Hours`, not the threshold alerts.
- **Keep background jobs healthy.** On this stack, a broken cron is the most
  common root cause of a full disk.
- Set a default quota; unlimited is a policy decision, usually an accidental one.
- Keep backups off-host.
