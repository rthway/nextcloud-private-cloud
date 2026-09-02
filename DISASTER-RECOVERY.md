# Disaster recovery

## Scope

Total loss — the host is gone, the disk is unrecoverable, or the data is
corrupted beyond repair. Component failures are in
[docs/runbooks/](docs/runbooks/).

## Objectives

| | Target | Status |
|---|---|---|
| **RPO** | 24 hours | determined by the nightly schedule |
| **RTO** | under 1 hour on replacement hardware | **not measured under real conditions** |

Both are targets. The only measured figure is a 6-second database restore of a
131-table schema on the author's laptop. **On this stack the file restore
dominates**, and it scales with how much data users have — a 500 GB instance
is bounded by disk and network throughput, not by anything in this repository.

**No full drill against a rebuilt host has been performed.** A destructive
restore into a running stack has, and is recorded in the README. Those are
different exercises and presenting one as the other would be dishonest.

## Prerequisites — verify these now

- [ ] A backup that has been **verified restorable** (`make backups` shows yes)
- [ ] That backup stored **somewhere other than the host it came from**
- [ ] The `age` private key stored off-host, if backups are encrypted
- [ ] **`config.php` is in the backup** — it holds `passwordsalt`, without
      which every user password is unverifiable. `verify-backup.sh` checks this
- [ ] DNS changeable by someone reachable
- [ ] The repository accessible

The most common reason a recovery fails is not a bad backup. It is a backup
sitting on the disk that died.

## Procedure

### 1. Assess and communicate (5 min)

```
Newest verified backup:  <timestamp>
Now:                     <timestamp>
Data loss window:        <difference>
```

State that number **before** starting. Users of a file-sync service will ask
"which of my files are gone", and the answer is "anything changed after this
time".

### 2. Provision a host (10–30 min)

Ubuntu 22.04+, sized per
[docs/architecture/capacity-planning.md](docs/architecture/capacity-planning.md).
**Disk is the constraint here** — it must hold the restored data plus room to
grow, and the restore itself needs space for the archive alongside the
extracted files.

### 3. Install and configure (10–20 min)

```bash
curl -fsSL https://get.docker.com | sh
sudo git clone https://github.com/rthway/nextcloud-private-cloud.git /opt/nextcloud-private-cloud
cd /opt/nextcloud-private-cloud
```

Restore the `.env` and `secrets/` you kept off-host. **Do not regenerate
them** — `MYSQL_PASSWORD` must match what is inside the backup's `config.php`,
and regenerating the admin password does nothing because it is only read at
first install.

Pin `NEXTCLOUD_VERSION` to the version recorded in the backup manifest.
Nextcloud has no downgrade path, and restoring into older code fails at the
schema check after the database is already gone.

### 4. Restore (time varies with data volume)

```bash
# Retrieve the backup into backups/, decrypting if needed:
age -d -i /path/to/key.txt -o backups/<id>/database.sql.gz backups/<id>/database.sql.gz.age
age -d -i /path/to/key.txt -o backups/<id>/data.tar.gz     backups/<id>/data.tar.gz.age
age -d -i /path/to/key.txt -o backups/<id>/config.tar.gz   backups/<id>/config.tar.gz.age

./scripts/verify-backup.sh <id>     # prove it before relying on it
docker compose up -d
./scripts/restore.sh <id> --yes
```

### 5. Cut over (5 min + DNS)

```bash
sudo certbot certonly --standalone -d "$NEXTCLOUD_DOMAIN" --agree-tos -m "$ACME_EMAIL"
docker compose -f compose.yml -f compose.prod.yml up -d
```

Then update DNS. **Lower the TTL in advance** — a 24-hour TTL turns a
40-minute recovery into a day-long one, and sync clients cache aggressively.

### 6. Validate

```bash
make health
./tests/test-smoke.sh
```

By hand:

- [ ] Log in. `status.php` returning 200 does not mean the app is coherent.
- [ ] **Open a file.** The only check that catches a database restored without
      its data directory.
- [ ] **Reconnect a sync client.** WebDAV under `/remote.php` is a different
      code path from the web UI and is what most users depend on.
- [ ] Confirm background jobs resume: `./scripts/occ.sh config:app:get core lastcron`
- [ ] If anything looks inconsistent: `./scripts/occ.sh files:scan --all`

### 7. Re-establish protection

**A recovered system with no backups is one failure from the same incident.**

```bash
./scripts/backup.sh
./scripts/verify-backup.sh
systemctl list-timers | grep nextcloud
```

## Failure scenarios

| Scenario | Response | Recovery |
|---|---|---|
| Host lost | full procedure | ~1 hour + file restore + DNS |
| Database volume corrupt | **copy it first**, then restore | ~30 min |
| Data volume lost | restore files only from the newest backup | scales with size |
| `config.php` lost | restore it — passwords are unverifiable without `passwordsalt` | minutes |
| Failed core/app upgrade | restore; there is no supported resume | ~30 min |
| Ransomware | restore from a backup predating the compromise; rotate every credential | hours |
| Object storage bucket deleted | versioning may allow recovery — see [ADR-005](docs/adr/005-object-storage.md) | varies |

## Practising this

An untested plan is a document, not a capability. Quarterly:

1. Provision a throwaway VM
2. Run the full procedure against a real backup
3. **Time each step** and record the actual numbers
4. Replace the RTO target here with what was measured
5. Note what went wrong — something always does

The weekly `verify-backup` timer exercises the restore path continuously,
which is why quarterly is enough rather than monthly.
