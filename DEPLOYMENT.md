# Deployment

Three paths, in increasing order of what has been proven.

| Path | Status |
|---|---|
| Local | **Verified** on the author's hardware |
| Single-host production | **Reference** — overlay renders, never deployed |
| Object storage | **Reference** — Terraform validates, never applied |

---

## 1. Local — verified

```bash
git clone https://github.com/rthway/nextcloud-private-cloud.git
cd nextcloud-private-cloud

make setup     # .env, secrets, local CA + certificate
make up        # builds and starts; Nextcloud installs itself
make health
```

`https://nextcloud.localhost:8444`. Import `config/nginx/tls/ca.pem` to
silence the browser warning.

**There is no `make init`.** The upstream image runs the Nextcloud installer
on first start from `NEXTCLOUD_ADMIN_USER` and `NEXTCLOUD_ADMIN_PASSWORD` —
unlike the Odoo project in this portfolio, which needs an explicit database
creation step.

First start takes a few minutes: the installer creates ~131 tables and enables
the bundled apps. `make up` blocks until healthy.

---

## 2. Single-host production — reference

### Sizing

4 vCPU / 8 GB is the reference. **Disk is the variable that matters** — it
must hold user data plus room for backups if they stay local, which they
should not. The arithmetic is in
[docs/architecture/capacity-planning.md](docs/architecture/capacity-planning.md);
read it before changing worker counts or memory limits, because several of
those numbers are coupled.

### Deploy

```bash
curl -fsSL https://get.docker.com | sh

sudo git clone https://github.com/rthway/nextcloud-private-cloud.git \
  /opt/nextcloud-private-cloud
cd /opt/nextcloud-private-cloud

mkdir -p secrets && chmod 700 secrets
for f in mysql_password mysql_root_password redis_password nextcloud_admin_password; do
  openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c 40 > "secrets/$f"
done
chmod 400 secrets/*

cp .env.example .env
$EDITOR .env      # NEXTCLOUD_DOMAIN, TRUSTED_DOMAINS, NEXTCLOUD_IMAGE, tag

sudo certbot certonly --standalone -d "$NEXTCLOUD_DOMAIN" --agree-tos -m ops@example.com

docker compose -f compose.yml -f compose.prod.yml up -d
./scripts/healthcheck.sh
./scripts/backup.sh && ./scripts/verify-backup.sh
```

**Pin `NEXTCLOUD_IMAGE_TAG` to a digest**, not a tag. A tag is a mutable
pointer; "the same version" must mean the same bytes. The release workflow
prints the digest and attaches build provenance.

### Two settings that must be right before users arrive

**`NEXTCLOUD_TRUSTED_DOMAINS`** — every hostname the instance answers on. A
request with an unlisted Host is refused, which is the defence against
host-header poisoning of password-reset links.

**`NEXTCLOUD_TRUSTED_PROXIES`** — the proxy's CIDR. Too broad and any client
can spoof `X-Forwarded-For`, defeating brute-force protection; too narrow and
every user appears to come from the proxy, so one user's failed logins throttle
everyone.

### Certificate renewal

Install the deploy hook, or renewal succeeds while nginx serves the old
certificate until it restarts for an unrelated reason — invisible until the
day it expires, at which point **every sync client stops too**:

```bash
sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh > /dev/null <<'EOF'
#!/bin/sh
cd /opt/nextcloud-private-cloud || exit 0
docker compose exec -T proxy nginx -s reload || true
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
sudo certbot renew --dry-run
```

`--dry-run` first, always: it uses staging and consumes no rate limit, whereas
five failed real attempts locks you out for a week.

### Scheduled backups

Install **both** timers. The verification timer is the one that proves the
backups are real:

```bash
sudo systemctl enable --now nextcloud-backup.timer nextcloud-backup-verify.timer
systemctl list-timers | grep nextcloud
```

---

## 3. Object storage — reference, never applied

```bash
cd infrastructure/terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

terraform init
terraform plan          # read this properly
terraform apply

terraform output env_snippet
terraform output -raw nextcloud_secret_access_key
```

Put the outputs in `.env` and recreate the app container.

> **Decide before the first upload.** Nextcloud does **not** migrate existing
> files when `objectstore` is enabled: it starts treating the bucket as the
> backend and files already on the local volume become invisible. Enabling it
> later is a real migration with downtime.
> See [ADR-005](docs/adr/005-object-storage.md).

**This changes backups.** File content moves to the bucket, so `backup.sh` no
longer captures it — the script detects this and warns rather than writing an
archive that looks complete. The bucket needs versioning and lifecycle rules,
which the Terraform provides.

### Migrating to a managed database

Odoo aside, Nextcloud cares about very little: a connection string.

| Component | Managed equivalent | Change |
|---|---|---|
| `db` | RDS / Cloud SQL / Azure Database for MariaDB | remove the service; point `MYSQL_HOST` at the endpoint |
| Data volume | S3 primary storage | see above |
| TLS | ALB / managed certificate | keep nginx for routing and static files |

**Set `transaction-isolation=READ-COMMITTED` and `binlog_format=ROW` on the
managed instance too.** They are parameter-group settings there rather than
command-line flags, and Nextcloud deadlocks without the first.

A managed database provides automated backups, PITR and failover — three
things this repository does not. For a service holding an organisation's
files, that is usually the right trade.

---

## Upgrading

### The stack

```bash
./scripts/backup.sh && ./scripts/verify-backup.sh    # not optional
git pull
docker compose -f compose.yml -f compose.prod.yml pull
docker compose -f compose.yml -f compose.prod.yml up -d
./scripts/occ.sh status      # check needsDbUpgrade
./scripts/healthcheck.sh
```

### Nextcloud itself

**Take and verify a backup first.** There is no rollback other than a restore,
and **Nextcloud does not support skipping major versions** — 33 to 35 must go
through 34.

The upstream image runs `occ upgrade` automatically on start when it detects a
newer version. Apps incompatible with the new version are **disabled rather
than loaded**, which is a safe failure but means functionality can disappear
silently. Check afterwards:

```bash
./scripts/occ.sh app:list          # anything unexpectedly disabled?
./scripts/occ.sh db:add-missing-indices
./scripts/occ.sh config:app:get core lastcron   # did cron survive?
```

Rehearse against a restored copy before touching production.
