# ADR-004: Redis for file locking, with `volatile-lru`

**Status:** Accepted · 2026-09-02

## Context

Nextcloud uses three distinct caching roles, and conflating them is the usual
mistake:

| Role | What it is |
|---|---|
| `memcache.local` | per-process, no network hop |
| `memcache.distributed` | shared across containers |
| `memcache.locking` | **transactional file locking** |

The third is not a cache. It is a correctness mechanism: it prevents two
processes writing the same file simultaneously.

## Decision

**APCu** for local, **Redis** for distributed and for locking — which is what
the upstream image already configures from `REDIS_HOST`. This repository does
not restate it, for a reason given below.

Redis is configured with `maxmemory-policy volatile-lru` and AOF persistence.

## `volatile-lru`, and why it is the load-bearing line

This is the single most consequential setting in `config/redis/redis.conf`.

`allkeys-lru` — the obvious choice for a cache — evicts *any* key under memory
pressure. Nextcloud's file locks carry no TTL. Under `allkeys-lru`, Redis is
therefore permitted to evict a live lock, which lets a second process write a
file another is already writing. **That is silent data corruption, not a cache
miss.**

`volatile-lru` only evicts keys that have an expiry set — cache entries, never
locks.

The trade is that once volatile keys are exhausted, writes fail with OOM
instead of silently evicting. That is the correct failure: a loud error beats
silent corruption. It is also why `RedisEvictingKeys` is a **correctness**
alert in this deployment rather than a capacity one.

AOF persistence is on for the same reason: a restart that drops the keyspace
leaves Nextcloud with database lock rows that no longer match Redis, which
surfaces as files that cannot be edited until `maintenance:repair` clears them.

## Why this repository does not configure Redis itself

The upstream image ships `redis.config.php`, which sets
`memcache.distributed`, `memcache.locking` and the whole `redis` array from
the environment. Verified, not assumed:

```bash
docker compose exec app cat /usr/src/nextcloud/config/redis.config.php
```

An earlier draft of this repository redefined those in its own managed config
to add a connection timeout. **Nextcloud merges config fragments with
`array_merge`**, so a nested array defined again in a later file *replaces* the
earlier one wholesale rather than merging into it — the redefinition would
have deleted upstream's host and password. The managed config now carries only
what upstream does not set, and says so.

## Alternatives considered

**Memcached.** Faster for pure caching. Rejected: no persistence, so every
lock is lost on restart, and no equivalent of `volatile-lru` to protect
non-expiring keys.

**Database locking** (Nextcloud's fallback). Rejected: it works, and it
produces "file is currently locked" errors under exactly the concurrent access
a shared file store exists to support.

**Valkey** — the BSD-3-Clause fork of Redis 7.2, and a drop-in replacement.

Genuinely appealing. Redis moved from BSD to a dual RSALv2/SSPLv1 model at 7.4
(adding AGPLv3 at 8.0), and none are OSI-approved open source. This deployment
uses Redis as an internal component of a self-hosted application, which is
squarely within what the licence permits — so the change is not required.

Not adopted only because the Redis image is what Nextcloud's documentation and
the upstream image's environment variables assume. **Anyone building a hosted
offering on this should read the SSPL terms and consider Valkey**, which is
noted in [../../NOTICE.md](../../NOTICE.md) rather than buried here.

## Consequences

- Redis is a hard dependency. `RedisDown` is critical, not a warning.
- `maxmemory` sits below the container limit so Redis manages its own pressure
  rather than being OOM-killed — a killed Redis loses every lock at once.
- `redis.conf` renames `CONFIG`, `FLUSHDB`, `FLUSHALL` and `KEYS` away, so an
  application bug or injection reaching Redis cannot flush the lock store.
  A side effect worth knowing: `CONFIG GET` no longer works, so the smoke test
  reads the policy from `INFO` instead.
