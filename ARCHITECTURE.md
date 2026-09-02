# Architecture

## Components

| Service | Image | Role | Exposed |
|---|---|---|---|
| `proxy` | nginx 1.31.4-alpine | TLS, static files, routing, rate limiting | 80, 443 on `BIND_ADDRESS` |
| `app` | derived from nextcloud:34.0.3-fpm-alpine | PHP-FPM pool | nothing |
| `cron` | **the same image** | `cron.php` every 5 minutes | nothing |
| `db` | mariadb:11.8.9 | metadata | nothing |
| `redis` | redis:8.8.2-alpine | cache **and file locking** | nothing |

Observability adds ten more, all opt-in.

## Networks

```
frontend (bridge)              backend (bridge, internal: true)
   proxy                          db
   app   <----------------------> redis
   cron  <---------------------->
   [observability]
```

**MariaDB and Redis are on the internal network only** — no route off the host
at all. A compromised datastore cannot call home, and a smoke test verifies
the database container cannot reach the internet.

The application tier is on both, because Nextcloud genuinely needs egress: the
app store, federation with other instances, SMTP, and object storage when
enabled. Confining it would harden it at the cost of most of what makes it a
private *cloud* rather than a file server.

**The proxy carries a network alias for the real domain.** Without it,
anything inside the stack reaching it by service name sends `Host: proxy`,
which Nextcloud rejects with HTTP 400 because it is not in `trusted_domains`.
Adding `proxy` to that list would weaken a real control against host-header
poisoning of password-reset links; an alias solves it without touching the
control.

## Request path

```
Browser / sync client
  |  HTTPS, TLS 1.2/1.3, HTTP/2
  v
nginx :443
  |-- *.css *.js *.png ... ----> served DIRECTLY from the volume, never PHP
  |-- /.well-known/ca[rl]dav --> 301 to /remote.php/dav/
  |-- /config /data /lib ------> 404 (blocked)
  |-- *.php (entry points only)  FastCGI -> app:9000
  |                                          |
  |                                          v
  |                                   MariaDB :3306  ·  Redis :6379
  '-- /remote.php/dav ---------> WebDAV: the sync-client path
```

**Static assets never enter PHP.** The web UI is thousands of small files;
routing them through FPM would occupy a worker per icon.

**PHP execution is restricted to Nextcloud's entry points.** An open
`location ~ \.php$` would let an uploaded `.php` file in the data directory
execute — on a server that accepts arbitrary uploads, that is remote code
execution by design.

## State

| State | Where | Lost means |
|---|---|---|
| File metadata, users, shares | `db-data` volume | restore from backup |
| **File content** | `nextcloud-data` volume | restore; or the S3 bucket if enabled |
| **`config.php`** | `nextcloud-html` volume | **every password becomes unverifiable** |
| File locks + cache | `redis-data` volume | stale locks until repaired |
| TLS material | host or `config/nginx/tls/` | reissue |

`config.php` deserves its emphasis: it holds `instanceid`, `secret` and
`passwordsalt`. A database restored with a different `passwordsalt` has users
whose stored hashes can never be verified. `verify-backup.sh` asserts both are
present in every backup.

## Configuration flow

```
Upstream image fragments            This repository
  redis.config.php          }         zz-managed.config.php.tmpl
  apcu.config.php           }              |
  reverse-proxy.config.php  }  merged      |  rendered by a before-starting hook
  s3.config.php             }  in filename |
  smtp.config.php           }  order       v
                                    config/zz-managed.config.php
```

Nextcloud merges every `*.config.php` in the config directory. The `zz-`
prefix makes this repository's fragment win.

**It carries only what upstream does not set.** Nextcloud merges with
`array_merge`, so a nested array defined again *replaces* the earlier one
wholesale — redefining `redis` to add a timeout would delete upstream's host
and password. Checked, not assumed:

```bash
docker compose exec app ls /usr/src/nextcloud/config/
```

Rendering happens in a `before-starting` hook — the image's documented
extension point — rather than a custom entrypoint racing the upstream one. An
earlier version rendered it first, creating `config/` as root; the installer
runs as `www-data`, could not write `config.php`, and produced an instance that
started cleanly and reported `installed: false` forever.

## Startup ordering

```
db (healthy: healthcheck.sh --connect --innodb_initialized)
redis (healthy: authenticated PING)
   |
app (healthy: FPM listening AND status.php reports installed)
   |
cron          proxy
```

Each gate means something specific:

- `--innodb_initialized`, not just `--connect`: MariaDB accepts connections
  before InnoDB has finished recovery, and that is exactly the window
  Nextcloud must not start in.
- Redis's check authenticates, because a bare `PING` returns `NOAUTH` once
  `requirepass` is set.
- The app's healthcheck does **two** things — an FPM liveness probe and
  `status.php` through the PHP CLI. Either alone gives a false pass: FPM can
  be alive while Nextcloud is broken, and Nextcloud can be fine while no
  workers are free.

`cron` has **no healthcheck by design**. It runs a sleep loop with no endpoint,
and a liveness probe would pass happily while `cron.php` failed every run.
Whether jobs actually run is monitored properly instead, via the `lastcron`
timestamp.

## Failure behaviour

| Failure | What happens | Recovery |
|---|---|---|
| A PHP worker dies | FPM replaces it | automatic |
| App container dies | `restart: unless-stopped` | automatic |
| MariaDB unclean shutdown | InnoDB recovery | automatic — **do not restart during it** |
| Redis restarts | AOF replays; locks survive | automatic |
| Redis lost entirely | file locking degrades | [runbook](docs/runbooks/redis-unavailable.md) |
| `cron.php` failing | **silent** — nothing looks wrong | [runbook](docs/runbooks/cron-not-running.md) |
| Disk full | uploads fail; MariaDB stops writing | [runbook](docs/runbooks/disk-full.md) |
| Certificate expires | browsers **and all sync clients** stop | [runbook](docs/runbooks/certificate-expired.md) |

`restart: unless-stopped`, not `always`: `always` resurrects containers an
operator deliberately stopped during an incident.

## What this architecture does not do

- **No HA.** Single node.
- **No horizontal scaling** until file content moves to object storage —
  the data directory is a shared mutable volume requiring RWX.
- **No zero-downtime deploys.**
- **Backups pause the instance** while quiescing, which is a deliberate trade
  for consistency.
