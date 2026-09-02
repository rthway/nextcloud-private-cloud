# Runbook: slow responses, high CPU, memory pressure

**Alerts:** `ContainerMemoryNearLimit`, `ContainerCpuThrottled`, `MariaDBSlowQueries`
**Severity:** warning

---

## Symptoms

Users report Nextcloud is slow, usually without errors. Four causes feel
identical from outside:

1. **PHP-FPM worker saturation** — requests queue.
2. **Throttling** — the CPU limit, not the work, is making things slow.
3. **Database degradation** — a missing index after an upgrade.
4. **Preview generation** — one job eating the CPU.

---

## Diagnosis

### 1. Is the worker pool saturated?

The first thing to check on a PHP-FPM stack:

```bash
docker compose exec -T proxy wget -qO- http://127.0.0.1:8081/fpm-status
```

`active processes` at `max children` means every worker is busy and nginx is
queueing. `slow requests` climbing points at what.

```bash
docker compose logs app --tail 200 | grep -i 'slowlog\|execution time'
```

`request_slowlog_timeout` is 30s, so anything logged there has a backtrace
naming the function — which is the fastest route from "it's slow" to a cause.

### 2. Throttling

```bash
docker stats --no-stream
docker run --rm --network nextcloud_frontend curlimages/curl:8.11.1 -s \
  --get --data-urlencode 'query=rate(container_cpu_cfs_throttled_seconds_total{name=~"nextcloud-.*"}[5m])' \
  http://prometheus:9090/api/v1/query
```

Anything sustained above zero means the limit is the constraint.

### 3. The database

```bash
set -a; source .env; set +a
docker compose exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" -T db mariadb -u root -e "
  SHOW GLOBAL STATUS LIKE 'Slow_queries';
  SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read%';"
```

A poor buffer-pool hit rate means `innodb_buffer_pool_size` is too small for
the working set — which on Nextcloud is dominated by `oc_filecache`.

**After any upgrade, check indexes before anything else:**

```bash
./scripts/occ.sh db:add-missing-indices
```

### 4. Previews

```bash
docker compose logs cron --tail 100 | grep -i preview
docker compose exec -T app du -sh /var/www/html/data/appdata_*/preview 2>/dev/null
```

Preview generation is the most CPU- and memory-hungry thing Nextcloud does. A
large photo library being scanned for the first time will saturate a small
host, and that is expected rather than a fault.

---

## Resolution

### Worker saturation

Raise `PHP_FPM_MAX_CHILDREN` **and** the app container's memory limit
together. Their product must fit inside the limit or the OOM killer replaces
queueing with crashes. The arithmetic is in
[../architecture/capacity-planning.md](../architecture/capacity-planning.md).

More workers than the CPU can serve makes latency worse, not better.

### Missing indexes

```bash
./scripts/occ.sh db:add-missing-indices
./scripts/occ.sh db:add-missing-columns
```

Safe to run at any time; it only adds what is absent.

### Buffer pool too small

Raise `innodb_buffer_pool_size` in `config/mariadb/my.cnf` and the db
container's memory limit together — roughly 50% of the container limit.

### Previews dominating

Narrow the provider list in `zz-managed.config.php`, or lower
`preview_max_x` / `preview_max_y`. Generating previews ahead of time during
quiet hours is the other option, via the `previewgenerator` app.

---

## Verification

```bash
docker compose exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" -T db mariadb -u root -e "FLUSH STATUS;"
```

Let normal traffic run, then re-check slow queries and the FPM status page.
Confirm throttling is back to zero on the dashboard.

---

## Prevention

- Run `occ db:add-missing-indices` after every upgrade as routine.
- Re-run the capacity arithmetic whenever worker counts or memory limits
  change — the three numbers are coupled.
- Watch `ContainerCpuThrottled`; it is invisible in load averages.
