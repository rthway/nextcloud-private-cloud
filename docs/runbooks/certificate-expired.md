# Runbook: TLS certificate expired or expiring

**Alerts:** `TLSCertificateExpiringSoon` (21 days), `TLSCertificateExpiringCritical` (7 days)
**Severity:** warning, escalating to a full outage on expiry

---

## Why this is worse for Nextcloud than for a website

On expiry, browsers refuse the site — and **every desktop and mobile sync
client stops too**. Sync clients do not offer a "proceed anyway" button. A
certificate expiry here is a total outage for every user and every device,
with a date known weeks in advance.

A working ACME client renews at 30 days. An alert at 21 days therefore means
renewal has **already failed at least once**.

## Symptoms

- `NET::ERR_CERT_DATE_INVALID` in browsers.
- Sync clients report connection or certificate errors.
- `probe_ssl_earliest_cert_expiry` approaching zero.

---

## Diagnosis

### 1. What is actually served, versus what is on disk?

```bash
echo | openssl s_client -connect "$NEXTCLOUD_DOMAIN:443" -servername "$NEXTCLOUD_DOMAIN" 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

openssl x509 -in config/nginx/tls/fullchain.pem -noout -dates
```

**A renewed file with an old certificate on the wire means nginx has not
reloaded.** It reads certificates at start and on reload, not per request.
This is the most common version of this incident — go straight to *nginx did
not reload*.

### 2. Why did renewal fail?

```bash
sudo certbot certificates
sudo systemctl status certbot.timer
sudo journalctl -u certbot --since '30 days ago' | tail -40
```

| Cause | Signature | Fix |
|---|---|---|
| http-01 challenge blocked | `Invalid response from http://.../.well-known/acme-challenge/` | *Challenge path* |
| DNS changed | `DNS problem: NXDOMAIN` | fix the record |
| Rate limited | `too many certificates already issued` | wait — 5 per domain per week |
| Timer not running | `certbot.timer` inactive | `sudo systemctl enable --now certbot.timer` |

---

## Resolution

### Renew

```bash
sudo certbot renew --dry-run     # prove it first; uses staging, no rate limit
sudo certbot renew
```

**Always `--dry-run` first.** Five failed real attempts locks you out for a
week, turning a fixable problem into a scheduled outage.

### Challenge path

The vhost serves `/.well-known/acme-challenge/` from `/var/www/certbot` over
plain HTTP, ahead of the HTTPS redirect and ahead of Nextcloud's own
`.well-known` handling:

```bash
echo ok | sudo tee /var/www/certbot/.well-known/acme-challenge/probe > /dev/null
curl -s "http://$NEXTCLOUD_DOMAIN/.well-known/acme-challenge/probe"   # expect: ok
sudo rm /var/www/certbot/.well-known/acme-challenge/probe
```

Note this vhost has **several** `.well-known` rules — for CalDAV, CardDAV,
webfinger and nodeinfo. The ACME block uses `^~` so it wins against them; if
someone reorders or edits those, ACME breaks and calendar sync keeps working,
so the damage is not obvious.

### nginx did not reload

```bash
docker compose exec proxy nginx -t
docker compose exec proxy nginx -s reload
```

Wire it into renewal so it stops being manual:

```bash
sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh > /dev/null <<'EOF'
#!/bin/sh
cd /opt/nextcloud-private-cloud || exit 0
docker compose exec -T proxy nginx -s reload || true
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

### Already expired

```bash
sudo certbot certonly --webroot -w /var/www/certbot -d "$NEXTCLOUD_DOMAIN" --force-renewal
docker compose exec proxy nginx -s reload
```

> **HSTS makes the self-signed stopgap useless here.** The two-year
> `Strict-Transport-Security` header means browsers that have visited before
> will not let users click through, and sync clients never would anyway. Plan
> for the real certificate.

---

## Verification

```bash
echo | openssl s_client -connect "$NEXTCLOUD_DOMAIN:443" -servername "$NEXTCLOUD_DOMAIN" 2>&1 \
  | grep -i "verify return code"
```

Expect `verify return code: 0 (ok)`. Check the whole chain — a missing
intermediate works in browsers that cached it and fails in sync clients, which
is reported as "it works on my laptop but not my phone".

Then reconnect a sync client.

---

## Prevention

- Deploy the renewal hook and prove it with `--dry-run`.
- Keep the 21-day alert routed to a person; its whole value is the margin.
- Monitor the certificate on the wire, not the file — the `blackbox-tls` job
  exists for exactly that reason.
