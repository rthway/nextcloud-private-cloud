# Security

## Reporting

Open a private security advisory on the GitHub repository. Please do not open
a public issue for an unpatched vulnerability.

This is a personal portfolio project with no SLA. Findings will be addressed
on a best-effort basis and genuine ones credited.

---

## Trust boundaries

```
Internet
   |  [1] TLS 1.2/1.3, forward secrecy, HSTS
   v
nginx ------------------ frontend network
   |  [2] the only ingress; app publishes no host port
   v
PHP-FPM (workers as www-data)
   |  [3] internal network: no route off the host
   v
MariaDB  ·  Redis
```

**[1]** TLS terminates at nginx. Traffic behind it is plaintext on a
host-local bridge — the first thing to revisit if the database moves off-box.

**[2]** nginx also decides which paths are executable. This is a stronger
control here than in most stacks, because Nextcloud accepts arbitrary uploads:
an open `location ~ \.php$` would make an uploaded `.php` file in the data
directory executable, which is remote code execution by design.

**[3]** MariaDB and Redis sit only on the internal network. A smoke test
verifies the database container cannot reach the internet. The application
tier is on both networks because Nextcloud genuinely needs egress.

---

## Controls

### Paths that must never be served

The highest-consequence control in this repository, asserted twice — once by a
configuration test against the vhost, once by a smoke test against the running
instance:

```
/config/config.php   → 404   (contains the database password)
/data/...            → 404   (every user's files)
/lib, /3rdparty      → 404
/db_structure.xml    → 404
```

PHP execution is restricted to Nextcloud's entry points, and `try_files
$fastcgi_script_name =404` guards against path traversal reaching arbitrary
files.

### Secrets

- Nothing committed. `.env`, `secrets/`, TLS keys and the rendered
  `monitoring/mysqld-exporter/my.cnf` are git-ignored, enforced by a
  `git ls-files` assertion and by Gitleaks over the **full history** — a secret
  committed and later removed is still in the repository.
- Compose uses `${VAR:?message}`: a missing secret is a **failed deploy, not a
  weak one**.
- Generated with `openssl rand`, filtered to `[A-Za-z0-9]` because `+ / =`
  break in URLs and connection strings.
- The entrypoint **refuses to start** on a well-known admin password.
- In production, secrets are files read once at start rather than environment
  variables — an environment variable is visible in `docker inspect`, in
  `/proc/<pid>/environ`, and in any crash reporter.
- The metrics exporter uses a dedicated `serverinfo` token, not the admin
  password.

### Application

- **`trusted_domains`** — a request with an unlisted Host is refused. This is
  Nextcloud's defence against host-header poisoning of generated links,
  including password-reset URLs. It is why internal clients reach the proxy
  through a **network alias** rather than by adding `proxy` to the list.
- **`trusted_proxies`** — Nextcloud reads `X-Forwarded-For` only from a listed
  address. Set too broadly, any client can spoof its address and defeat
  brute-force protection; too narrowly, one user's failed logins throttle
  everyone.
- **Brute-force protection** enabled, with Argon2id parameters raised.
- **Login rate limiting** at nginx, keyed by a `map` so it does not interfere
  with location routing.
- **Default quota** set — unlimited means one user can fill the disk for
  everyone.

### Redis

`redis.conf` renames `CONFIG`, `FLUSHDB`, `FLUSHALL`, `KEYS` and `SHUTDOWN`
away, so an application bug or an injection reaching Redis cannot flush the
lock store or reconfigure it. Authentication is required; a smoke test
verifies an unauthenticated command is refused.

**`maxmemory-policy volatile-lru`** is a security-relevant setting, not just a
tuning one: `allkeys-lru` would permit evicting file locks, which is silent
data corruption. See [ADR-004](docs/adr/004-redis-and-caching.md).

### Containers

| Control | Applied |
|---|---|
| Non-root **workers** | PHP-FPM workers run as `www-data`; asserted by a smoke test |
| `no-new-privileges` | every service; asserted |
| Read-only root | nginx only — see accepted risks |
| Capabilities dropped | `cap_drop: ALL` in production, minimal add-back |
| Resource limits | memory and CPU on every service |
| Pinned images | a test rejects `:latest` |
| No published ports | db, redis, app, cron; asserted |

### Supply chain

Trivy (filesystem and image), Gitleaks over full history, hadolint,
ShellCheck, yamllint, `terraform validate`, SBOM per release, build provenance
attestation, Dependabot.

**A real vulnerability was found and fixed, not suppressed.** Trivy reported
two fixable HIGH CVEs in `libexpat` (CVE-2026-66046, CVE-2026-76641) inherited
from the base image. The Dockerfile now applies security updates to inherited
OS packages, trading some build reproducibility for not shipping
known-vulnerable packages — the right way round for an internet-facing file
store.

### Scanning policy

Vulnerabilities fail the build on HIGH/CRITICAL **where a fix exists**.
Unfixable findings are counted and reported rather than suppressed: a
permanently red pipeline trains everyone to ignore it, and then a fixable
CRITICAL goes unnoticed too. Leaked secrets fail unconditionally.

---

## Accepted risks

Each is a real weakness with a real reason.

### The Dockerfile ends as root

PHP-FPM's master process needs root to create the pool listener and to
populate the html volume on first start. An image forced to a non-root `USER`
does not start.

Both hadolint (DL3002) and Trivy (DS-0002) flag this, and it is the **only**
suppression in the repository — recorded in `.trivyignore` with its reasoning.
The compensating controls are asserted rather than claimed: the smoke suite
verifies the *workers* run as `www-data`, capabilities are dropped in
production, and `no-new-privileges` is set everywhere.

### The app container is not read-only

Nextcloud writes into `/var/www/html` during app installation and every
upgrade. A read-only root filesystem would still permit those writes (it is a
volume) while blocking PHP's session and opcache paths — producing a container
that starts and fails at first login. nginx *is* read-only.

### cAdvisor runs privileged

The most privileged container here, and it needs to be to read cgroup state.
*Mitigation:* opt-in overlay only. *Alternative:* drop it and keep
node_exporter, losing per-container attribution.

### Promtail mounts the Docker socket

Read access to it is close to root on the host. Mounted `:ro`, opt-in only.
*Alternative:* a socket proxy exposing only the endpoints Promtail needs —
described, not implemented.

### Backups are unencrypted by default

`BACKUP_AGE_RECIPIENT` is empty in the example. `backup.sh` warns on every
run, and **fails** rather than writing plaintext if encryption was requested
and `age` is missing.

### Backups pause the instance

Maintenance mode is downtime. A backup killed with SIGKILL can leave the
instance offline, because the trap that clears it never runs. `make health`
reports this loudly for that reason.

### TLS terminates at the proxy

Traffic between nginx, PHP-FPM, MariaDB and Redis is plaintext on a host-local
bridge. Acceptable for one host; the first thing to change if any of them
moves off-box. Note `sslmode`/TLS is also disabled on the exporter's database
connection, which is correct only because that network has no route off the
host.

---

## Not covered

- **Nextcloud application vulnerabilities.** Upstream's responsibility; keep
  the image current.
- **Third-party apps.** Anything installed from the app store runs with full
  access to user data. Review what you install.
- **Nextcloud's own sharing and permission model** — configured in the
  application.
- **Client-side (end-to-end) encryption.**
- **Physical and cloud-provider security.**
