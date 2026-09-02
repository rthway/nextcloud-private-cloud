# ADR-001: nginx + PHP-FPM, on Compose

**Status:** Accepted · 2026-09-02

## Context

Nextcloud is a PHP application. It can be deployed as a single container
bundling Apache and PHP, or split into nginx and PHP-FPM. It also needs a
database, a cache, and something to run scheduled jobs.

The target is a single host serving one organisation's files.

## Decision

Five services on Compose: `proxy` (nginx), `app` (PHP-FPM), `cron`, `db`
(MariaDB), `redis`. No Kubernetes.

The `app` and `cron` services share a YAML anchor so they cannot drift.

## Alternatives considered

**The `nextcloud:apache` image — one container.** Simpler, and the officially
easiest path.

Rejected for two reasons. First, Nextcloud's web UI is thousands of small
static files; with Apache's `mod_php` every one of them occupies a PHP
process. Splitting means nginx serves them directly and PHP workers are
reserved for requests that need PHP. Second, PHP-FPM's worker count becomes
tunable independently of connection count, which is the lever that actually
matters when the instance is slow.

**A separate cron implementation** — host cron, or a systemd timer calling
`docker exec`.

Rejected: a cron running a *different* Nextcloud version than the web
container corrupts data during an upgrade. Sharing the image via a YAML anchor
makes that impossible by construction. It also means one `docker compose pull`
updates both.

**Kubernetes.** Rejected for the same reason as the Odoo project in this
portfolio, plus one specific to Nextcloud: the data directory is a shared
mutable volume requiring RWX. Until that moves to object storage, the HTTP
tier is not genuinely stateless and an orchestrator cannot scale it.
[SCALING.md](../../SCALING.md) sets out the order in which that changes.

**Running PHP-FPM as a non-root user.** Rejected because it does not work: the
master process needs root to create the pool listener and to populate the html
volume on first start. It drops to `www-data` for every worker, which is where
request handling happens — and the smoke suite asserts that, because it is the
fact the "don't run as root" rule is a proxy for.

Both hadolint (DL3002) and Trivy (DS-0002) flag this. Both are suppressed with
this reasoning recorded, and nothing else is.

## Consequences

**Accepted:**

- Five services to reason about instead of one.
- The nginx vhost is long and must be right. A missing `location` block leaks
  `config/` — which contains the database password. The configuration suite
  asserts each of those blocks exists.
- No rolling deploys; `docker compose up -d` recreates containers.

**Gained:**

- Static assets never enter PHP.
- Worker count is an environment variable, not an image rebuild.
- The cron container cannot drift from the app container.
- nginx terminates TLS, rate-limits login, and enforces which paths are
  executable — all of which a single Apache container would do less directly.

## When to revisit

When the data directory moves to object storage. That removes the RWX
constraint, makes the HTTP tier genuinely stateless, and is the prerequisite
for anything horizontal.
