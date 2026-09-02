# Troubleshooting

Start here:

```bash
make health
```

It reads and never writes, so it is safe at any time.

## Symptom index

| Symptom | Likely cause | Runbook |
|---|---|---|
| Site unreachable, 502/504 | **stuck maintenance mode**, or FPM saturated | [application-down](docs/runbooks/application-down.md) |
| `status.php` OK but `/login` 500s | failed app or core upgrade | [application-down](docs/runbooks/application-down.md) |
| "File is currently locked" | Redis down, or locking misconfigured | [redis-unavailable](docs/runbooks/redis-unavailable.md) |
| Trash never empties, shares never expire | **background jobs stopped** | [cron-not-running](docs/runbooks/cron-not-running.md) |
| Disk filling steadily | usually the above | [disk-full](docs/runbooks/disk-full.md) |
| Uploads fail | disk, or upload limits | [disk-full](docs/runbooks/disk-full.md) |
| Slow, no errors | FPM saturation, missing index, previews | [high-cpu](docs/runbooks/high-cpu.md) |
| Sync clients stopped, browser warns | certificate | [certificate-expired](docs/runbooks/certificate-expired.md) |
| Random "database deadlock" | isolation level drifted | [database-unavailable](docs/runbooks/database-unavailable.md) |
| Backup failing | | [backup-failed](docs/runbooks/backup-failed.md) |
| Need to restore | | [restore-database](docs/runbooks/restore-database.md) |

## First-run problems

### Nextcloud reports `installed: false` forever

The container starts, logs "Cannot write into config directory", and never
installs. The config directory is owned by root and the installer runs as
`www-data`.

This repository renders its managed config from a `before-starting` hook
precisely to avoid it — an earlier version used a custom entrypoint that ran
first and created `config/` as root. If you add your own entrypoint logic, do
not touch `/var/www/html` before the upstream entrypoint has run.

### HTTP 400 "Access through untrusted domain"

The Host header is not in `NEXTCLOUD_TRUSTED_DOMAINS`. Add the hostname —
**quoted**, because the value contains spaces:

```bash
NEXTCLOUD_TRUSTED_DOMAINS="nextcloud.example.com localhost"
```

Internal clients (the metrics exporter, smoke tests) reach the proxy through a
Docker **network alias** rather than by adding `proxy` to this list, because
the list is a real security control.

### `.env`: `localhost: command not found`

An unquoted value containing a space. Valid Compose, a syntax error to bash —
and every script here does `source .env`. A configuration test asserts
`.env.example` survives sourcing.

### nginx: `"client_max_body_size" directive invalid value`

A `${VAR}` placeholder reached nginx literally. The image's envsubst pass
processes **only** `/etc/nginx/templates`; `nginx.conf` is mounted directly and
is never templated. Put anything needing substitution in the vhost template.

### `/login` returns 500, everything else works

`The requested uri(/login) cannot be processed by the script '/index.php/login'`
in the logs. A `location` block matched after the `try_files` rewrite and
bypassed `fastcgi_split_path_info`, so `SCRIPT_NAME` and `REQUEST_URI`
disagree.

This is why login rate limiting here uses a `map` at server level rather than
its own `location` block.

### Port conflicts

Defaults are 8081/8444 bound to `127.0.0.1`. Change `HTTP_PORT`, `HTTPS_PORT`,
`GRAFANA_PORT`, `PROMETHEUS_PORT` in `.env`.

## Platform-specific

### Windows / Git Bash: "no such file or directory" for a path that exists

MSYS rewrites absolute POSIX arguments into Windows paths before handing them
to a native binary, so `/var/www/html` reaches Docker as
`C:/Program Files/Git/var/www/html`. Every script guards against it:

```bash
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 ;;
esac
```

The guard has a side effect: with it set, *host* paths passed to native tools
stop being converted too, which is why the scripts use container-native probes
rather than host `curl`.

### `openssl req -subj` rejected

Same cause. `gen-local-tls.sh` drives OpenSSL from config files rather than
`-subj`, because setting `MSYS_NO_PATHCONV=1` fixes `-subj` and simultaneously
breaks every `-out` path.

### node-exporter: "not a shared or slave mount"

Docker Desktop and WSL2 reject the `rslave` propagation flag, so it is omitted.
Under Docker Desktop, node_exporter also reports the WSL2 VM rather than
Windows — the series are right for alerts; do not read disk figures as
describing your laptop.

## Diagnostic commands

```bash
make health
docker compose ps                          # state AND health differ
docker compose logs -f app
docker compose logs app --tail 200 | grep -iE '"level":[34]'   # Nextcloud errors

./scripts/occ.sh status
./scripts/occ.sh check
./scripts/occ.sh config:app:get core lastcron          # are jobs running?
./scripts/occ.sh config:system:get memcache.locking    # is Redis locking?

# Are all PHP workers busy?
docker compose exec -T proxy wget -qO- http://127.0.0.1:8081/fpm-status

# Redis: policy and evictions
set -a; source .env; set +a
docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning info memory \
  | grep -E 'maxmemory_policy|used_memory_human'
```

**`CONFIG GET` will not work** — `redis.conf` renames `CONFIG` away as
deliberate hardening. Use `INFO`.
