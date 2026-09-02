# Runbook: Nextcloud is down

**Alerts:** `NextcloudDown`, `NextcloudLoginDown`, `PrometheusTargetDown`
**Severity:** critical

---

## Symptoms

- Users report the site is unreachable, or the browser shows 502/504.
- Desktop and mobile sync clients stop and report connection errors.
- `probe_success` is 0 for `/status.php` or `/login`.

## Possible causes

Ordered by how often they turn out to be the answer:

1. Stuck in maintenance mode — usually a backup that failed partway.
2. PHP-FPM has no free workers, so nginx queues and then times out.
3. MariaDB is unavailable, so the app cannot start.
4. A failed app or core upgrade left the schema half-migrated.
5. The disk is full.
6. nginx is up but cannot reach PHP-FPM.

**`status.php` passing while `/login` fails is diagnostic**, not a curiosity:
`status.php` is deliberately lightweight and does not exercise the full
request path. That combination almost always means a failed upgrade or a PHP
fatal error in an app.

---

## Diagnosis

Work outside-in.

### 1. What does the stack think of itself?

```bash
make health
docker compose ps
```

Read the **health** column, not just state. Compose reports `running` for a
container whose healthcheck is failing.

### 2. Maintenance mode

The first thing to check, because it is both the most common cause and the
fastest fix:

```bash
./scripts/occ.sh status
```

If `maintenance: true` and no backup or upgrade is running:

```bash
./scripts/occ.sh maintenance:mode --off
```

`scripts/backup.sh` clears maintenance mode in a trap on exit, so this state
normally means the process was killed rather than failing.

### 3. Is PHP-FPM answering, and does it have free workers?

```bash
docker compose logs app --tail 100
docker compose exec -T proxy wget -qO- http://127.0.0.1:8081/fpm-status
```

The FPM status page is the one that answers "are all workers busy" — the
container healthcheck cannot, because it only proves the listener is open.

`active processes` equal to `max children` means the pool is saturated:
requests queue at nginx and then 504. Look for what is holding them —
usually large uploads, preview generation, or a slow database.

### 4. Nextcloud's own errors

```bash
docker compose logs app --tail 200 | grep -iE '"level":[34]'
```

Levels 3 and 4 are error and fatal. `log_type` is `errorlog`, so these go to
the container log rather than into a file inside the data directory.

### 5. Can nginx reach PHP-FPM?

```bash
docker compose exec proxy nginx -t
docker compose logs proxy --tail 50 | grep -i 'upstream\|error'
```

`connect() failed (111: Connection refused)` means FPM is not listening — back
to step 3. `upstream timed out` means it is alive but slow.

---

## Resolution

### Stuck in maintenance mode

```bash
./scripts/occ.sh maintenance:mode --off
make health
```

### Worker pool exhausted

Immediate relief, then find the cause:

```bash
docker compose restart app
```

That is mitigation, not a fix — it will recur. If it is genuinely load rather
than one pathological request, raise `PHP_FPM_MAX_CHILDREN` **and** the app
container's memory limit together: their product must fit inside the limit, or
the OOM killer replaces the queueing problem with a crash.

### Failed upgrade

```bash
./scripts/occ.sh status          # look for needsDbUpgrade: true
./scripts/occ.sh upgrade
```

If the upgrade itself fails, the schema is half-migrated and there is no
supported resume. Restore:

```bash
./scripts/restore.sh <backup-id>
```

### A broken app

```bash
docker compose logs app --tail 200 | grep -oE '"app":"[^"]+"' | sort | uniq -c | sort -rn | head
./scripts/occ.sh app:disable <app>
docker compose restart app
```

---

## Verification

```bash
make health
```

Then log in through a browser. **`status.php` returning 200 is not enough** —
it does not exercise the ORM or the app stack.

Confirm a sync client reconnects too: WebDAV under `/remote.php` is a
different code path from the web UI, and it is what most users actually
depend on.

---

## Prevention

- Take and verify a backup before every core or app upgrade. There is no
  rollback other than a restore.
- Rehearse upgrades against a restored copy first.
- Keep `make health` running on a schedule — it catches stuck maintenance mode
  before users do.
