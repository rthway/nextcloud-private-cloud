# Runbook: MariaDB unavailable or degraded

**Alerts:** `MariaDBDown`, `MariaDBConnectionsHigh`, `MariaDBSlowQueries`, `MariaDBAborted`
**Severity:** critical when down

---

## Symptoms

- Nextcloud returns 500s, or reports "Internal Server Error" on every page.
- `mysql_up` is 0.
- Uploads fail; the web UI loads but file listings are empty.

## Possible causes

1. Connection exhaustion — PHP-FPM workers cannot get a connection.
2. The disk is full; MariaDB cannot extend a tablespace or the binlog.
3. The container was OOM-killed and is in InnoDB recovery.
4. A long-running transaction holding locks.
5. Credentials disagree between `.env` and the database volume.

---

## Diagnosis

### 1. Is it up?

```bash
set -a; source .env; set +a
```

```bash
docker compose ps db
docker compose exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" -T db mariadb -u root -e "SELECT 1;"
```

If the container is restarting:

```bash
docker compose logs db --tail 100
```

| Log line | Meaning | Action |
|---|---|---|
| `InnoDB: Starting crash recovery` | normal after an unclean stop — **wait** | do not restart |
| `Disk is full writing` | disk | [disk-full.md](disk-full.md) |
| `Access denied for user` | `.env` and the volume disagree | *Credential mismatch* below |
| `Table ... is marked as crashed` | corruption | *Corruption* below |

> **Never restart MariaDB during InnoDB crash recovery.** It looks like a hang
> and is not. Restarting begins recovery again from the start. Watch
> `docker compose logs -f db` and wait for `ready for connections`.

### 2. Connections

```bash
docker compose exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" -T db mariadb -u root -e "
  SELECT COUNT(*) AS total,
         SUM(COMMAND = 'Sleep') AS idle,
         @@max_connections AS max_conn
  FROM information_schema.processlist;"
```

Budget is roughly `PHP_FPM_MAX_CHILDREN` plus cron, the exporter and operator
headroom. `max_connections` is 100 in `config/mariadb/my.cnf`.

### 3. Locks and long transactions

```bash
docker compose exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" -T db mariadb -u root -e "
  SELECT trx_id, trx_state, trx_started,
         TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_s,
         LEFT(trx_query, 80) AS query
  FROM information_schema.innodb_trx
  ORDER BY trx_started;"
```

### 4. The two settings that must not drift

```bash
docker compose exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" -T db mariadb -u root -e "
  SELECT @@transaction_isolation, @@binlog_format;"
```

`READ-COMMITTED` and `ROW`. Nextcloud deadlocks intermittently under
MariaDB's default `REPEATABLE-READ`, and the symptom — random "database
deadlock" errors under concurrency — reads like load and is really an
isolation mismatch.

---

## Resolution

### Kill a blocking transaction

```bash
docker compose exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" -T db mariadb -u root -e "KILL <trx_mysql_thread_id>;"
```

The transaction rolls back, so no committed data is lost — but the user's
in-flight operation fails, which for a large upload means repeating it.

### Connection exhaustion

```bash
docker compose restart app cron
```

Then fix the budget rather than the symptom. **Raising `max_connections` is
usually wrong**: each connection costs memory, and raising it without raising
the container limit converts a connection error into an OOM kill. Prefer
lowering `PHP_FPM_MAX_CHILDREN` to what the CPU can actually serve.

### Credential mismatch

The password inside the data directory is authoritative; changing `.env` does
not change it. Either restore the old value, or change it in the database:

```bash
docker compose exec -e MYSQL_PWD="<OLD_ROOT_PW>" -T db mariadb -u root -e "
  ALTER USER 'nextcloud'@'%' IDENTIFIED BY '<NEW>';
  FLUSH PRIVILEGES;"
```

Then update `.env`, re-run `./scripts/gen-secrets.sh` to re-render the exporter
credentials, and recreate the consumers.

### Corruption

**Stop. Do not restart, and do not run `REPAIR TABLE` yet.**

1. Copy the volume as it stands:
   ```bash
   docker run --rm -v nextcloud_db-data:/data:ro -v "$PWD/backups:/out" \
     alpine tar -czf /out/corrupt-db-$(date -u +%Y%m%dT%H%M%SZ).tar.gz -C /data .
   ```
2. Verify your newest backup: `./scripts/verify-backup.sh`
3. Restore: see [../../DISASTER-RECOVERY.md](../../DISASTER-RECOVERY.md)

### Slow queries after an upgrade

Almost always a missing index. Nextcloud ships a command for exactly this:

```bash
./scripts/occ.sh db:add-missing-indices
./scripts/occ.sh db:add-missing-columns
./scripts/occ.sh db:add-missing-primary-keys
```

---

## Verification

```bash
make health
```

The MariaDB section must pass, including the isolation and character-set
checks. Then load a file listing in the web UI — that exercises `oc_filecache`,
which is the table everything depends on.

---

## Prevention

- Watch `MariaDBSlowQueries` after every Nextcloud upgrade.
- Keep the connection budget under review whenever `PHP_FPM_MAX_CHILDREN`
  changes; `make validate` asserts it still fits.
- Alert on disk before it is full.
