# Runbook: Redis unavailable or evicting

**Alerts:** `RedisDown`, `RedisEvictingKeys`, `RedisMemoryHigh`
**Severity:** critical for down, warning for eviction — but eviction is a
**correctness** problem here, not a capacity one

---

## Why Redis is not "just a cache" in this stack

Redis serves two roles for Nextcloud, and they have opposite requirements:

| Role | Losable? |
|---|---|
| Distributed cache | Yes. Losing an entry costs a cache miss. |
| **Transactional file locking** | **No.** Losing a lock lets two processes write the same file. |

`memcache.locking` points at Redis. Without it, Nextcloud falls back to
database locking, and under concurrent access users get *"file is currently
locked"* errors that read like data corruption.

This is why `config/redis/redis.conf` uses `maxmemory-policy volatile-lru`
rather than `allkeys-lru`: file locks carry no TTL, and `volatile-lru` only
evicts keys that have one. It is also why persistence (AOF) is on — a restart
that drops the keyspace leaves Nextcloud with database lock rows that no
longer match Redis.

## Symptoms

- `redis_up` is 0, or `make health` reports Redis not responding.
- Users report "file is locked" errors, especially on shared folders.
- Uploads fail or hang.
- `redis_evicted_keys_total` is climbing.

---

## Diagnosis

### 1. Is it up?

```bash
docker compose ps redis
set -a; source .env; set +a
docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping
```

Expect `PONG`. `NOAUTH` means the password is wrong — check `REDIS_PASSWORD`
in `.env` against what the container was started with.

### 2. Is it evicting?

```bash
docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning info stats \
  | grep -E 'evicted_keys|keyspace'
docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning config get maxmemory-policy
```

**`maxmemory-policy` must be `volatile-lru`.** If it is `allkeys-lru` or
`allkeys-random`, Redis is permitted to evict file locks, and that is silent
corruption rather than a cache miss. Fix the config and restart.

### 3. Memory pressure

```bash
docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning info memory \
  | grep -E 'used_memory_human|maxmemory_human'
```

Under `volatile-lru`, once volatile keys are exhausted Redis returns OOM on
writes rather than evicting locks. **That is the correct failure** — a loud
error beats silent corruption — but it is still a failure.

### 4. Are locks actually stuck?

```bash
docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning --scan --pattern 'files_lock*' | head -20
```

---

## Resolution

### Redis is down

```bash
docker compose up -d redis
docker compose logs redis --tail 50
```

If it will not start, check the AOF file — a truncated append-only file after
an unclean shutdown is the usual cause:

```bash
docker compose run --rm --entrypoint redis-check-aof redis --fix /data/nextcloud.aof
```

`redis-check-aof --fix` truncates to the last valid command. Some cache
entries are lost; that is acceptable. Locks lost this way are cleared in the
next step.

### Clear stale file locks

After any Redis restart, Nextcloud may hold lock rows that no longer
correspond to anything:

```bash
./scripts/occ.sh maintenance:mode --on
./scripts/occ.sh files:cleanup
./scripts/occ.sh maintenance:repair
./scripts/occ.sh maintenance:mode --off
```

If specific files remain locked, clear them directly:

```bash
docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning --scan --pattern 'files_lock*' \
  | xargs -r docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning del
```

**Only do this when you are certain no upload or sync is in progress.**
Deleting a live lock is exactly the corruption the lock exists to prevent.

### Eviction is happening

1. Confirm `maxmemory-policy` is `volatile-lru`. If not, that is the bug.
2. If it is, Redis genuinely needs more memory. Raise `maxmemory` in
   `config/redis/redis.conf` **and** the container limit in `compose.yml` —
   `maxmemory` must stay below the container limit so Redis manages its own
   pressure rather than being OOM-killed.

### Emergency: run without Redis

Nextcloud works without Redis, more slowly and with database locking. This is
a stopgap, not a fix:

```bash
./scripts/occ.sh config:system:delete memcache.locking
./scripts/occ.sh config:system:delete memcache.distributed
```

Expect "file is locked" errors under concurrency. Restore the settings as soon
as Redis is healthy — note that `zz-managed.config.php` does **not** set them,
so they come back from the image's `redis.config.php` on the next container
restart.

---

## Verification

```bash
make health
```

The caching section must report file locking via Redis, Redis responding, and
nothing evicted. Then upload a file through the web UI and confirm it
completes without a lock error.

---

## Prevention

- Never change `maxmemory-policy` to an `allkeys-*` value.
- Keep AOF persistence on, so locks survive a restart.
- Watch `RedisEvictingKeys` — treat any eviction as a signal to check the
  policy before assuming it is only capacity.
