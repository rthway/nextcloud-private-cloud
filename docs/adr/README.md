# Architecture decision records

One file per decision that was genuinely contested — where a competent
engineer could reasonably have chosen otherwise, and where the reasoning is
expensive to reconstruct later. Decisions that were obvious are not recorded.

| # | Decision | Status |
|---|---|---|
| [001](001-container-strategy.md) | nginx + PHP-FPM split, Compose, not Kubernetes | Accepted |
| [002](002-version-and-release-channel.md) | Newest stable Nextcloud, pinned | Accepted |
| [003](003-database-selection.md) | MariaDB 11.8 LTS rather than PostgreSQL | Accepted |
| [004](004-redis-and-caching.md) | Redis for locking; `volatile-lru`; Valkey noted | Accepted |
| [005](005-object-storage.md) | Optional S3 primary storage via Terraform | Accepted |
| [006](006-observability.md) | serverinfo exporter plus a cron-timestamp sidecar | Accepted |
| [007](007-tls-and-http-security.md) | Headers at the proxy; no CSP of our own | Accepted |

Each records **Context**, **Decision**, **Alternatives considered** and
**Consequences** — including the consequences we did not want.
