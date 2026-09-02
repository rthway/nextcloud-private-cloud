# ADR-003: MariaDB 11.8 LTS

**Status:** Accepted · 2026-09-02

## Context

Nextcloud supports MariaDB, MySQL, PostgreSQL and SQLite. SQLite is unsuitable
for anything multi-user. The choice is genuinely open between MariaDB and
PostgreSQL, and both are well supported.

## Decision

**MariaDB 11.8 LTS**, with three settings that are not optional.

## Alternatives considered

**PostgreSQL.** Technically excellent, and the Odoo project in this portfolio
uses it. Genuinely defensible here too.

Chosen against for ecosystem reasons rather than technical ones: MariaDB/MySQL
is what Nextcloud's documentation, its admin manual, its `occ` tooling
defaults and the overwhelming majority of community troubleshooting assume.
When something goes wrong at 3am, the search results are about MySQL. That is
a real operational property.

Using MariaDB here also means this portfolio demonstrates both engines with
genuine depth rather than the same one twice.

**MySQL 8.** Broadly equivalent. MariaDB chosen for its clearer LTS cadence
and because Nextcloud's own documentation leads with it.

## The settings that are not optional

These three cause failures that look like something else entirely, which is
why they are set explicitly and asserted by tests:

**`--transaction-isolation=READ-COMMITTED`.** Nextcloud deadlocks
intermittently under MariaDB's default `REPEATABLE-READ`. The symptom is
sporadic "database deadlock" errors under concurrent access — which reads like
load and is really an isolation mismatch.

**`--binlog-format=ROW`.** Nextcloud generates non-deterministic statements
that STATEMENT-based replication reproduces incorrectly, silently diverging a
replica or a point-in-time restore from the original.

**`utf8mb4`, not `utf8`.** MariaDB's "utf8" is three-byte and cannot store
emoji or many CJK characters. A user creating a folder with an emoji in its
name gets an incomprehensible error.

The first two are set on the command line because they must apply before the
config file is read; a configuration test asserts they are still there.

## Tuning

`config/mariadb/my.cnf` is sized for the reference host (4 vCPU / 8 GB, db
container capped at 2 GB) and shaped by Nextcloud's access pattern: many small
indexed reads against `oc_filecache`, short write transactions on upload, and
occasional large scans during `files:scan`. It is read-dominated, which is why
`innodb_buffer_pool_size` at 50% of the container limit matters more than
anything else in the file.

`innodb_flush_log_at_trx_commit = 1` stays. Setting 2 is a real throughput win
and a real way to lose a second of committed transactions on power loss —
which for a file-sync server means the database forgetting files that exist on
disk, recoverable only by a full `files:scan`.

## Consequences

- Single point of failure; vertical scaling only.
- Memory settings derive from the container limit, not host RAM. The
  arithmetic is in
  [../architecture/capacity-planning.md](../architecture/capacity-planning.md),
  and a CI check asserts the connection budget still fits.
- A managed database (RDS, Cloud SQL) would provide automated backups, PITR
  and failover. Not used here because there is no cloud account, and
  documenting one as deployed would be a fabrication —
  [../../DEPLOYMENT.md](../../DEPLOYMENT.md) sketches the migration.
