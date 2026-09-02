# Capacity planning

Every memory and connection number in this repository is derived here. The
point of writing it down is that several of these values are coupled, and
changing one alone is the usual cause of the next incident.

## Reference host

**4 vCPU, 8 GB RAM, SSD.** Every default is sized for this. Memory numbers are
derived from *container limits*, not host RAM.

## Memory budget

```
Host                                       8.0 GB
  MariaDB container limit                  2.0 GB
  Nextcloud (app) container limit          4.0 GB   <-- a ceiling, not a reservation
  cron container limit                     1.0 GB
  Redis container limit                    0.5 GB
  nginx container limit                    0.25 GB
  Host OS, Docker, page cache              ~1.0 GB
```

Limits sum above host RAM deliberately: they are ceilings at which Docker
kills the process tree, not memory held. The `reservations` blocks express the
floor.

The observability stack adds roughly 2.5 GB of limits, which is why it is
opt-in.

## The coupled numbers — read this before changing anything

```
PHP_FPM_MAX_CHILDREN   32        concurrent PHP requests
PHP_MEMORY_LIMIT       1024M     per request, worst case
app container limit    4 GB      Docker kills the tree here
```

**32 × 1 GB is 32 GB, far above the 4 GB limit.** That is deliberate and safe,
because `memory_limit` is a per-request *ceiling* that almost no request
approaches — a typical Nextcloud request uses tens of megabytes. The ceiling
exists for the outliers: preview generation of a large image, or a chunked
upload assembly.

The failure mode to avoid is the reverse: if enough workers simultaneously do
something expensive, the container OOMs and **every** in-flight request dies,
rather than PHP rejecting one request with a clean error.

So the practical rule is:

- raise `PHP_FPM_MAX_CHILDREN` only with evidence from the FPM status page
  that workers are actually saturated
- raise the container limit alongside it
- if memory is tight, lower `PHP_MEMORY_LIMIT` first — that converts an OOM
  kill into a single failed request, which is a much better failure

CI runs with `PHP_FPM_MAX_CHILDREN=6` for exactly this reason: a 2 vCPU runner
cannot serve 32 workers, and oversubscribing makes the stack slower to become
healthy rather than faster.

## Connection budget

Asserted by a CI test:

```
  PHP-FPM workers          32     roughly one connection each
+ cron                      4
+ mysqld_exporter           3
+ operator / backup         5
                          ----
                           44     inside max_connections = 100
```

**Raising `max_connections` is usually the wrong fix** for connection
exhaustion: each connection costs memory, so raising it without raising the
container limit converts a connection error into an OOM kill. Prefer lowering
`PHP_FPM_MAX_CHILDREN` to what the CPU can actually serve.

`tests/test-config.sh` recomputes this from `.env.example` and `my.cnf` and
fails if the sum no longer fits.

## MariaDB, within its 2 GB

```
innodb_buffer_pool_size   1G      50% of the container limit
tmp_table_size            64M     per connection when used
sort/read/join buffers    1-2M    per connection, per operation
```

The buffer pool matters more than anything else here: Nextcloud is
read-dominated against `oc_filecache`, and if that table's hot pages fit in
memory, queries are fast.

50% rather than the usual "70–80% of RAM" advice, because that advice assumes
a dedicated database server. Inside a container it must leave room for
connections, sort buffers and server overhead, or the OOM killer takes the
database.

## Redis

```
container limit   512M
maxmemory         384M    deliberately below the container limit
```

Redis manages its own pressure rather than being OOM-killed — a killed Redis
loses every file lock at once. With `volatile-lru`, once volatile keys are
exhausted Redis returns OOM on writes instead of evicting locks, which is the
correct failure.

## PHP-FPM worker count

Start from CPU, not from memory:

```
max_children ≈ 2 × vCPU        for a mixed IO/CPU workload
```

On 4 vCPU that is roughly 8–32 depending on how IO-bound the workload is;
32 is generous and assumes most requests are waiting on the database or disk.

**More workers than the CPU can serve makes latency worse**, not better: they
compete for CPU and each holds a database connection.

The signal to raise it is `active processes` at `max children` on the FPM
status page, not user complaints.

## Storage

| Consumer | Growth | Notes |
|---|---|---|
| User files | with usage | the point of the service |
| **Trash** | 30-day retention | grows without bound if cron stops |
| **File versions** | 90-day retention | same |
| Previews | with image libraries | regenerable; safe to delete |
| MariaDB | with metadata, not content | `oc_filecache` dominates |
| Binlog | 7-day expiry | |
| Backups | ~17 copies at steady state | |

**On this stack, a full disk is most often caused by background jobs having
stopped** — trash and versions never expire. That is why the disk runbook
checks `lastcron` before anything else.

Backups on the same volume as the data they protect is a self-inflicted
outage.

## Scaling up

| Host | buffer pool | MAX_CHILDREN | db limit | app limit |
|---|---|---|---|---|
| 4 vCPU / 8 GB | 1 GB | 32 | 2 GB | 4 GB |
| 8 vCPU / 16 GB | 4 GB | 64 | 6 GB | 8 GB |
| 16 vCPU / 32 GB | 8 GB | 128 | 12 GB | 16 GB |

Past roughly 16 vCPU the ceiling stops being CPU and becomes the single-writer
database and the shared data volume. [../../SCALING.md](../../SCALING.md)
covers what changes there — and why object storage comes first.
