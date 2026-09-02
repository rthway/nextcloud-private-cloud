# Monitoring

```bash
make up-obs      # Grafana :3002, Prometheus :9092
```

Opt-in: it roughly doubles the memory footprint.

## What is measured

Unlike the Odoo project in this portfolio, **Nextcloud exposes real
application metrics** through its bundled `serverinfo` app.

| Signal | Source |
|---|---|
| Users, files, storage, shares by type | serverinfo exporter |
| **Last background-job run** | a sidecar (see below) |
| Availability, TLS expiry | blackbox_exporter |
| Connections, slow queries, buffer pool | mysqld_exporter |
| Memory, **evictions**, clients | redis_exporter |
| Request rate, connection state | nginx stub_status |
| Container CPU, memory, throttling | cAdvisor |
| Host CPU, memory, disk | node_exporter |

## The metric written by hand

**The most valuable alert here is "background jobs have stopped."** That
failure is silent: the cron container stays up and healthy while `cron.php`
fails on every run, and trash, shares and file scans quietly stop for weeks.

No exporter publishes Nextcloud's `lastcron` value. Rather than ship an alert
referencing a metric nothing produces, a ~30-line sidecar
(`monitoring/cron-metrics/export-cron-metric.sh`) reads it via `occ` and
writes `nextcloud_last_cron_timestamp_seconds` into node_exporter's textfile
collector.

Details worth knowing if you change it:

- it reuses the Nextcloud image, so `occ` always matches the running version
- it runs as root only to take ownership of the volume Docker creates
  `root:root`, then drops to `www-data` — `occ` as root leaves root-owned files
  Nextcloud cannot read
- it writes to a temp path and `mv`s into place, because node_exporter parses
  that directory on every scrape and a half-written file discards **every**
  metric in it

## What is NOT measured, and why

**There is no alert on 5xx rate.** `nginx-prometheus-exporter` reads
`stub_status`, which has no per-status-code breakdown; open-source nginx has
no endpoint that does (it is an nginx Plus feature).

Rather than write an approximation and call it "error rate", the status view
comes from the nginx JSON access log in Loki, parsed into a `status` label at
ingest. The dashboard panel says so. The outside-in blackbox probes are what
page.

Also absent: per-endpoint timings and distributed tracing.

## Alerts

18 rules. Every one names a runbook, and a test asserts both that the
annotation exists and that the file it points at does.

The ones specific to this stack:

- **`NextcloudCronStale`** — the silent failure above. There is no other
  signal for it.
- **`RedisEvictingKeys`** — a **correctness** alert, not capacity. Redis holds
  the file locks, and `redis.conf` uses `volatile-lru` so keys without a TTL
  can never be evicted. Any eviction means either the policy changed or
  pressure is high enough to be worth knowing.
- **`RedisDown`** — critical rather than a cache warning, for the same reason.
- **`DiskWillFillIn24Hours`** — trend rather than threshold. On a file-sync
  server this is the most useful alert available; it buys working hours.
- **`MariaDBSlowQueries`** — usually a missing index after an upgrade.
  Nextcloud ships `occ db:add-missing-indices` precisely because this happens.
- **`PrometheusTargetDown`** — monitoring that fails silently is worse than
  none, because it is trusted.

**Alertmanager is not deployed.** Rules evaluate and are visible in
Prometheus; nothing routes them to a human yet. Stated rather than implied.

## Dashboard

One provisioned dashboard, read-only in the UI — edits made by clicking are
lost on the next restart, so the provisioning declares that explicitly.

Panels follow the order an investigation actually takes: is it up, what is it
storing, is locking healthy, is the database coping, what are we returning,
are we out of resources. The background-jobs panel is in the top row because
it is the one that goes unnoticed.

No panel displays a value this deployment does not genuinely measure.

## Logs

Promtail parses at ingest rather than at query time:

- **nginx** — JSON parsed; `status` and `request_method` become labels
- **Nextcloud** — JSON parsed; numeric `level` mapped to a readable name, so
  panels and queries do not need a lookup table
- **cron** — separated from the app container, so a failing `cron.php` is
  greppable without wading through request logs
- **MariaDB** — level extracted

Label discipline matters: Loki builds an index stream per unique label
combination, so promoting a request ID to a label would create one stream per
request.

```logql
{service="app", level_name="ERROR"}                      # Nextcloud errors
{service="proxy"} | json | status >= 400                 # non-2xx
{service="cron"}                                          # did cron.php fail?
{service="proxy"} | json | request_time > 5              # slow requests
```

## Deliberate implementation choices

**Loki declares no healthcheck.** Its image is distroless — no shell, no wget,
no curl — so nothing inside it can probe its own endpoint. blackbox_exporter
probes `/ready` over the network instead, which verifies reachability from
outside and is the better check.

**mysqld_exporter reads a config file**, not `DATA_SOURCE_NAME`: the env-var
form is deprecated upstream and a connection string in the environment is
visible in `docker inspect`. The file is rendered from `.env` by
`gen-secrets.sh` and git-ignored.

**cAdvisor metrics are filtered hard** — seven metric families kept, which is
what makes 15 days of retention fit.

## Verifying the pipeline

```bash
# Expect 11/11
docker run --rm --network nextcloud_frontend curlimages/curl:8.11.1 -s \
  http://prometheus:9090/api/v1/targets | grep -c '"health":"up"'

# Is the hand-written metric flowing?
docker run --rm --network nextcloud_frontend curlimages/curl:8.11.1 -s \
  http://node-exporter:9100/metrics | grep nextcloud_last_cron

make validate     # includes promtool check config and check rules
```
