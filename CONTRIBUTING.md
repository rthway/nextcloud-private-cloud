# Contributing

## What this repository is

Infrastructure and operations engineering around Nextcloud. **It contains no
Nextcloud application code and should not acquire any.** Nextcloud apps belong
in their own repository.

## Getting set up

```bash
git clone https://github.com/rthway/nextcloud-private-cloud.git
cd nextcloud-private-cloud
make setup && make up
make test
```

`make test` runs 142 checks in about 90 seconds. Run it before you start, so
you know the baseline was green.

## The standard for a change

**Every non-obvious decision is explained where it lives.** A configuration
file that says *what* without *why* costs the next person an afternoon.

Not this:

```yaml
maxmemory-policy volatile-lru
```

This:

```
# volatile-lru, NOT allkeys-lru.
#
# allkeys-lru evicts any key under pressure -- including file locks, which
# have no TTL. Evicting a lock lets a second process write a file another is
# already writing. That is silent corruption, not a cache miss.
maxmemory-policy volatile-lru
```

The test is whether someone changing the value in six months would know what
they are trading away.

## Check before you assume

Two things were **removed** from this repository after the upstream image was
actually inspected: a `pecl install` layer for extensions that were already
present, and duplicate cache/proxy/S3 configuration the image already
generates. The second was worse than redundant — Nextcloud merges config with
`array_merge`, so the redefinition would have deleted upstream's Redis
credentials.

Before adding anything, check:

```bash
docker run --rm --entrypoint php nextcloud:34.0.3-fpm-alpine -m
docker compose exec app ls /usr/src/nextcloud/config/
```

## Rules

**Never commit a credential.** Gitleaks scans full history in CI. If you do
commit one, rotate it — removing it in a later commit does not make it
uncommitted.

**Pin versions.** No `:latest`; a test rejects it.

**Do not weaken an invariant to make a test pass.** These are asserted
deliberately:

- db, redis, app and cron publish no host port; the backend network is internal
- MariaDB runs READ-COMMITTED with ROW binlog and utf8mb4
- `memcache.locking` is Redis and `maxmemory-policy` is `volatile-lru`
- `backgroundjobs_mode` is `cron`
- `config/`, `data/`, `lib/`, `3rdparty/` return 404
- PHP execution is restricted to Nextcloud's entry points
- security headers appear exactly once each

If a change genuinely requires breaking one, that is an ADR, not a test edit.

**Every new alert names a runbook, and that runbook must exist.** Both are
enforced.

**Fix vulnerabilities; do not suppress them.** Exactly one suppression exists
(`DS-0002`/`DL3002`, in `.trivyignore`) and it carries its full reasoning. Two
real CVEs were fixed rather than ignored.

**Never claim something was verified unless it was.** The README's
"Verification status" table distinguishes *verified locally*, *validated
syntactically*, and *reference architecture, never deployed*. Its entire value
is its accuracy.

Use **Target RPO/RTO**, never *Achieved*, unless measured — and say what
against.

## Before opening a pull request

```bash
make lint validate security smoke
```

If you touched backup, restore, or anything about storage:

```bash
make backup && make verify-backup
```

That is not a formality. Backup and restore are the two paths whose failure is
discovered at the worst possible moment.

## Commits

Conventional Commits. Write the body for someone reading it during an
incident: what changed, why, and what breaks if it is wrong.

Do not split one change across several commits to inflate a contribution
graph, and do not bundle unrelated changes to save typing.

## Architecture decision records

Write one when a competent engineer could reasonably have chosen otherwise.
Follow the existing format: Context, Decision, Alternatives considered,
Consequences — **including the ones you did not want**.

Do not write one for a decision that was obvious; it buries the ones that
matter.

## What will not be accepted

- Kubernetes manifests. [ADR-001](docs/adr/001-container-strategy.md) explains
  the scope; argue the scope first.
- Nextcloud apps or PHP application code.
- Suppressing a scanner finding to go green.
- Tests that assert `true`.
- Dashboards or figures presenting values that were not measured.
