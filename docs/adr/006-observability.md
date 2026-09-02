# ADR-006: serverinfo metrics, plus a sidecar for the one that matters

**Status:** Accepted · 2026-09-02

## Context

Unlike the Odoo project in this portfolio — where the application exposes no
metrics at all and everything is inferred from nginx and the database —
Nextcloud ships a `serverinfo` app publishing an OCS endpoint with user
counts, file totals, storage, shares by type and active sessions.

## Decision

Scrape `serverinfo` via a maintained third-party exporter, authenticated with
a dedicated token; add mysqld, redis, nginx, blackbox, cAdvisor and node
exporters; and write one metric ourselves.

## The metric nothing provides

**The most valuable Nextcloud alert is "background jobs have stopped."**

That failure is completely silent. The cron container stays up and healthy
running its sleep loop while `cron.php` fails on every invocation. Trash never
expires, shares never lapse, file scans never run, and the database fills with
rows nothing cleans up. Weeks pass before anyone notices, and by then the disk
is usually the symptom.

There is no process-level signal. The only evidence is that Nextcloud's own
`lastcron` value stops advancing — and the serverinfo exporter does not
publish it.

The options were to ship an alert referencing a metric nothing produces, or to
produce it. A ~30-line sidecar reads `lastcron` via `occ` and writes it into
node_exporter's textfile collector:

- it reuses the Nextcloud image, so there is no second image to maintain and
  `occ` is guaranteed to match the running version
- it runs as root only to take ownership of the volume Docker creates
  `root:root`, then drops to `www-data` — `occ` as root leaves root-owned
  files in the data directory that Nextcloud cannot read afterwards
- it writes to a temp path and moves into place, because node_exporter parses
  that directory on every scrape and a half-written file discards **every**
  metric in it

## Authentication

A dedicated `serverinfo` token, not the admin password. The token grants
read-only access to one endpoint, so a compromised exporter can read metrics
and administer nothing.

## What is deliberately not measured

**There is no alert on 5xx rate.** `nginx-prometheus-exporter` reads
`stub_status`, which exposes connection counters and a total request count and
no breakdown by status code. Open-source nginx has no endpoint that provides
one; it is an nginx Plus feature.

Writing an approximation and labelling it "error rate" would be worse than
leaving the gap visible, so the status-code view comes from the nginx JSON
access log in Loki, parsed into a `status` label at ingest. The dashboard panel
says where its data comes from. The outside-in blackbox probes are what page.

## Two problems found by building it

**Boolean flags.** `mysqld_exporter` uses kingpin, where booleans are
`--no-<flag>` rather than `=false`. `--collect.slave_status=false` was parsed
as a positional argument and the exporter exited with "unexpected false, try
--help".

**Host headers.** The exporter reaching the proxy by service name sent
`Host: proxy`, which Nextcloud rejects with HTTP 400 because it is not in
`trusted_domains`. The tempting fix — adding `proxy` to `trusted_domains` —
weakens a real control against host-header poisoning of password-reset links.
Fixed with a Docker network alias instead, so internal clients present the
same Host a browser would.

## Alternatives considered

**Writing an exporter.** Rejected: more code to own for the same result. The
third-party one is small, maintained and pinned.

**Nextcloud's own Prometheus app.** Community apps installed into the database
run inside the application whose health they report on, and lag major
versions. The serverinfo app is bundled and supported.

**Loki-derived alerts** for the cron signal. Rejected: it would depend on a
log line whose format is not a contract, and the sidecar reads the value
Nextcloud itself uses.

## Consequences

- One sidecar to maintain, sharing the app image so version skew is impossible.
- Alertmanager is **not** deployed. Rules are evaluated and visible in
  Prometheus; nothing routes them to a human yet. Stated plainly rather than
  implied.
- Loki's filesystem backend has no replication: logs live and die with the
  volume. Accepted for a single node where logs are a debugging aid rather
  than an audit record.
