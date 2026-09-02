# Operations

Day-to-day running. Incidents are in [docs/runbooks/](docs/runbooks/);
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) indexes them by symptom.

## `occ` is the operational interface

Almost everything not clickable happens through Nextcloud's CLI:

```bash
./scripts/occ.sh status
./scripts/occ.sh user:list
./scripts/occ.sh app:list
./scripts/occ.sh check
```

**Always through the wrapper.** `occ` must run as `www-data`; run as root — as
a bare `docker compose exec` does — it creates root-owned files in the data
directory that Nextcloud cannot read afterwards. The symptom appears later, at
the next upload into an affected folder, and the fix is a recursive `chown`
nobody enjoys discovering.

## Daily

```bash
make health
```

Beyond the usual, it checks the things that fail silently here: background
jobs are in `cron` mode and `lastcron` is recent, Redis is doing the locking
and has evicted nothing, MariaDB is still `READ-COMMITTED` and `utf8mb4`, and
the newest backup has been verified.

Exit 0 means everything passed, so it works as a cron check:

```bash
0 8 * * * cd /opt/nextcloud-private-cloud && ./scripts/healthcheck.sh --quiet \
          || echo "Nextcloud health check failed" | mail -s nextcloud ops@example.com
```

## Weekly

- Confirm the verification timer ran: `systemctl list-timers | grep nextcloud`
- `./scripts/occ.sh check` — Nextcloud's own configuration warnings
- Review Dependabot pull requests
- Check disk trend, not just the current figure

## Monthly

- Apply base image updates (Dependabot raises them; CI proves them)
- `./scripts/occ.sh db:add-missing-indices` — cheap and safe
- Review trash and version storage against retention
- Confirm certificate renewal: `sudo certbot certificates`

## Quarterly

- **A full disaster recovery drill against a rebuilt host.** Time each step
  and replace the RTO target in
  [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md) with what was measured.
- Re-run the capacity arithmetic against actual usage
- Review quotas

---

## Routine procedures

### Restart without touching data

```bash
make restart      # app, cron and proxy
```

### Apply a configuration change

`zz-managed.config.php` is rendered at container start, so changes to it or to
`.env` need a recreate:

```bash
docker compose up -d --force-recreate app cron
```

nginx changes need only a reload — but test first:

```bash
docker compose exec proxy nginx -t
docker compose exec proxy nginx -s reload
```

### Install or upgrade an app

**Back up first.** A failed app upgrade can leave the schema half-migrated.

```bash
./scripts/backup.sh && ./scripts/verify-backup.sh
./scripts/occ.sh app:install <app>
./scripts/occ.sh app:list
```

Afterwards check `/login` specifically, not just `status.php` — the health
endpoint can pass while the app stack is broken, and that is exactly what a
failed app upgrade looks like.

### Add a user, set a quota

```bash
./scripts/occ.sh user:add --display-name "Jane" jane      # prompts
./scripts/occ.sh user:setting jane files quota "20 GB"
```

Unlimited quota means one user can fill the disk for everyone.
`NEXTCLOUD_DEFAULT_QUOTA` sets the default for new accounts.

### Reconcile files with what is on disk

Needed after a restore, or if files were placed on the volume directly:

```bash
./scripts/occ.sh files:scan --all
```

On a large instance this takes hours, which is why nothing runs it
automatically.

### Rotate credentials

**`MYSQL_PASSWORD` needs care.** The password inside the data directory is
authoritative; changing `.env` does not change it.

```bash
set -a; source .env; set +a
NEW=$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c 40)

# 1. Change it IN the database
docker compose exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" -T db mariadb -u root -e \
  "ALTER USER '$MYSQL_USER'@'%' IDENTIFIED BY '$NEW'; FLUSH PRIVILEGES;"

# 2. Then .env
sed -i "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=$NEW|" .env

# 3. Re-render the exporter credentials, which are derived from .env
./scripts/gen-secrets.sh

# 4. Recreate the consumers
docker compose up -d --force-recreate app cron mysqld-exporter
./scripts/healthcheck.sh
```

**`NEXTCLOUD_ADMIN_PASSWORD` is only read at first install.** On a running
instance:

```bash
./scripts/occ.sh user:resetpassword admin
```

### Maintenance mode

```bash
./scripts/occ.sh maintenance:mode --on
# ... work ...
./scripts/occ.sh maintenance:mode --off
```

`backup.sh` does this automatically and clears it in a trap. **A backup killed
with SIGKILL never runs its trap**, so a stuck maintenance mode is the usual
aftermath of an interrupted backup — and `make health` reports it loudly for
that reason.

### Query the database

```bash
make db-shell
```

**Be careful.** Nextcloud maintains `oc_filecache` alongside the filesystem;
changing rows directly desynchronises them, and the repair is `files:scan`.

---

## Scheduled jobs

| Timer | When | Purpose |
|---|---|---|
| `nextcloud-backup` | daily 02:30 | three artefacts, quiesced, then retention |
| `nextcloud-backup-verify` | Sunday 04:00 | prove the newest restores |
| `certbot` | twice daily | renewal |
| Nextcloud's own cron | every 5 min | inside the `cron` container |

```bash
systemctl list-timers | grep -E 'nextcloud|certbot'
./scripts/occ.sh config:app:get core lastcron
```

---

## Things that will bite you

**`docker compose ps` shows `running` for a container whose healthcheck is
failing.** `make health` reads health.

**The `cron` container being up proves nothing.** It is a sleep loop. Only
`lastcron` shows whether jobs actually run.

**A stuck maintenance mode is an outage.** Check it first when the site is
down; it is the most common cause and the fastest fix.

**Never restart MariaDB during InnoDB recovery.** It looks like a hang and is
not; restarting starts recovery from the beginning.

**`docker system prune --volumes` will delete your data.** "Unused" includes
volumes of stopped stacks. Use `docker builder prune` and `docker image prune`.

**Redis restarting loses in-flight locks.** AOF persistence limits this, but
after an unclean Redis restart, `occ maintenance:repair` clears stale locks.

**Object storage cannot be enabled on an instance with data** without a real
migration.
