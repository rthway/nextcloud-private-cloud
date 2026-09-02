# Runbook: background jobs have stopped

**Alerts:** `NextcloudCronStale`
**Severity:** warning, and it degrades into a real problem quietly

---

## Why this matters more than it looks

Nextcloud does a great deal of work outside the request path: expiring trash
and file versions, lapsing shares, scanning for files changed on disk,
generating previews, pruning activity and notification rows, and running app
maintenance.

**All of it stops silently.** The cron container stays up, healthy, running
its sleep loop. Nothing in `docker compose ps` looks wrong. Users notice weeks
later when the disk is full of trash that should have expired, or a share that
should have lapsed is still live.

This is the failure this deployment's monitoring exists to catch, and it is
why a sidecar publishes `nextcloud_last_cron_timestamp_seconds` — no exporter
provides it.

## Symptoms

- `nextcloud_last_cron_timestamp_seconds` stops advancing.
- `make health` reports background jobs last ran too long ago.
- Nextcloud's admin overview shows "Last background job execution ran X hours
  ago".
- Trash and version history grow without ever shrinking.

---

## Diagnosis

### 1. Confirm it, and by how much

```bash
./scripts/occ.sh config:app:get core lastcron
date +%s
```

The difference is the age. Under five minutes is normal — the cron container
runs `cron.php` every five minutes.

### 2. Is the mode even right?

```bash
./scripts/occ.sh config:system:get backgroundjobs_mode
```

Must be `cron`. If it says `ajax`, jobs only run when someone loads a page —
which on a quiet instance means almost never. This is the single most common
Nextcloud misconfiguration, and `zz-managed.config.php` sets it deliberately:

```bash
./scripts/occ.sh config:system:set backgroundjobs_mode --value cron
```

If it has reverted, something is overwriting the managed config — check that
`config/zz-managed.config.php` still exists in the container.

### 3. Is the container running, and what does it say?

```bash
docker compose ps cron
docker compose logs cron --tail 100
```

**A running container proves nothing here.** `/cron.sh` is a loop that sleeps
and invokes `cron.php`; if every invocation fails, the loop carries on
happily.

### 4. Run it by hand and watch

This is the step that actually finds the cause:

```bash
docker compose exec --user www-data -T cron php -f /var/www/html/cron.php
```

| Output | Cause | Fix |
|---|---|---|
| `Nextcloud is in maintenance mode` | a backup left it on, or an upgrade stalled | `./scripts/occ.sh maintenance:mode --off` |
| `Not installed` / database errors | the cron container cannot reach MariaDB | [database-unavailable.md](database-unavailable.md) |
| `Allowed memory size exhausted` | a job needs more than PHP's limit | raise the cron container's memory and `PHP_MEMORY_LIMIT` |
| `PHP Fatal error` in an app | a broken or half-upgraded app | disable it: `./scripts/occ.sh app:disable <app>` |
| nothing, exits 0 | jobs ran — the timestamp should now advance | recheck step 1 |

### 5. Is one job wedged?

A single job that never completes blocks the queue behind it:

```bash
set -a; source .env; set +a
docker compose exec -e MYSQL_PWD="$MYSQL_PASSWORD" -T db \
  mariadb -u "$MYSQL_USER" "$MYSQL_DATABASE" -e "
    SELECT id, class, last_run, reserved_at
    FROM oc_jobs
    WHERE reserved_at > 0
    ORDER BY reserved_at ASC LIMIT 10;"
```

A row with an old `reserved_at` is a job that claimed the queue and never
released it. Preview generation and `files:scan` on a large instance are the
usual culprits.

```bash
# Release a stuck reservation. The job re-runs on the next cycle.
docker compose exec -e MYSQL_PWD="$MYSQL_PASSWORD" -T db \
  mariadb -u "$MYSQL_USER" "$MYSQL_DATABASE" -e "
    UPDATE oc_jobs SET reserved_at = 0 WHERE id = <ID>;"
```

---

## Resolution

Once the cause is fixed:

```bash
docker compose restart cron
sleep 300
./scripts/occ.sh config:app:get core lastcron    # must have advanced
```

If jobs have not run for a long time, the backlog is real — trash and versions
that should have expired are still there. Clear it deliberately rather than
waiting:

```bash
./scripts/occ.sh trashbin:expire
./scripts/occ.sh versions:expire
```

Both can take a long time on a neglected instance. Run them when the instance
is quiet.

---

## Verification

```bash
make health
```

The Nextcloud section must report background jobs ran within the last few
minutes. Then confirm the metric is flowing again, since that is what the
alert reads:

```bash
docker run --rm --network nextcloud_frontend curlimages/curl:8.11.1 -s \
  http://node-exporter:9100/metrics | grep nextcloud_last_cron
```

---

## Prevention

- Keep `NextcloudCronStale` routed somewhere a person reads. There is no other
  signal for this.
- Give the cron container enough memory for preview generation — it is the
  job that most often dies on the default.
- After any Nextcloud or app upgrade, check `lastcron` explicitly. A failed
  app migration frequently breaks cron while leaving the web UI working.
