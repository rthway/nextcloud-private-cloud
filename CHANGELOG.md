# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Semantic versioning applies to the infrastructure here — **not** to Nextcloud,
whose version is pinned in `.env.example` and recorded in
[NOTICE.md](NOTICE.md).

## [Unreleased]

Nothing yet.

## [1.0.0] — 2026-09-02

Initial release, verified on the author's hardware. See the README's
Verification status table for exactly what that covers and what it does not.

### Added

**Stack**
- Five services: nginx, PHP-FPM, cron, MariaDB 11.8 LTS, Redis 8.8
- nginx serves static assets directly; PHP workers are reserved for PHP
- `app` and `cron` share a YAML anchor so they cannot drift between versions
- MariaDB with READ-COMMITTED isolation, ROW binlog and utf8mb4 — none
  optional, all asserted by tests
- Redis configured for **file locking** as much as caching: `volatile-lru` so
  locks cannot be evicted, AOF so they survive a restart, and destructive
  commands renamed away
- nginx vhost blocking `config/`, `data/`, `lib/`, `3rdparty/`; PHP execution
  restricted to Nextcloud's entry points; CalDAV/CardDAV discovery
- Managed config fragment carrying only what the upstream image does not set

**Backup and recovery**
- Three artefacts — database, files, and config including `passwordsalt`
- **Quiesced** via maintenance mode, so the dump and the file archive describe
  the same instant
- `verify-backup.sh` restores into a throwaway schema and cross-references
  `oc_filecache` against the archive
- `restore.sh` restores **files before the database**, and stops the cron
  container as well as the app

**Observability**
- serverinfo exporter for real application metrics
- A sidecar publishing `nextcloud_last_cron_timestamp_seconds`, because no
  exporter provides the one signal that matters most
- 18 alert rules, each naming a runbook that exists
- One provisioned dashboard, 23 panels, none showing an unmeasured value

**Testing**
- Four suites, 142 checks: lint 27, configuration 46, security 14, smoke 55

**CI/CD**
- Build, scan, start, install, smoke, then **backup, verify and destructively
  restore**
- Release workflow scans before pushing, publishes an SBOM and provenance, and
  rebuilds weekly
- Terraform `fmt`, `init` and `validate`

**Infrastructure**
- Terraform for S3 primary storage and backups, with two IAM identities so the
  application cannot delete the backups protecting it

**Documentation**
- Seven ADRs, nine runbooks, and the operational document set

### Fixed

- Two real HIGH CVEs in `libexpat` inherited from the base image
  (CVE-2026-66046, CVE-2026-76641), by applying security updates to inherited
  OS packages rather than suppressing the finding

### Known limitations

Single node, no HA. RPO 24 hours. Backups pause the instance. The production
overlay and the Terraform have never been run against anything real. No load
testing. Alertmanager not deployed. Object storage cannot be enabled on an
instance that already holds data without a migration. Full list in the README.

[Unreleased]: https://github.com/rthway/nextcloud-private-cloud/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/rthway/nextcloud-private-cloud/releases/tag/v1.0.0
