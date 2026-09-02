#!/bin/sh
# ---------------------------------------------------------------------------
# Nextcloud container entrypoint.
#
#   1. Resolve secrets, preferring *_FILE (Docker secrets).
#   2. Fail fast on anything missing.
#   3. Render the PHP-FPM pool from the environment.
#   4. Chain to the upstream entrypoint, which owns install, upgrade, and
#      the before-starting hook that renders the managed configuration.
#
# Step 4 matters: Nextcloud's upgrade path is intricate (occ upgrade, app
# compatibility checks, database migrations). Wrapping the upstream entrypoint
# keeps all of that; replacing it would mean reimplementing it.
# ---------------------------------------------------------------------------
set -eu

log() { printf '%s entrypoint: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# --- 1. Secrets ------------------------------------------------------------
# For NAME, if NAME_FILE is set and readable, its contents win. The same image
# then consumes a Docker secret in production and a plain env var locally
# without a second code path.
resolve_secret() {
    _name="$1"
    eval "_file=\${${_name}_FILE:-}"
    if [ -n "${_file}" ]; then
        [ -r "${_file}" ] || die "${_name}_FILE points at ${_file}, which is not readable"
        # Strip the trailing newline `echo secret > file` leaves behind --
        # MariaDB rejects the password with a generic auth error otherwise.
        _value="$(tr -d '\n' < "${_file}")"
        export "${_name}=${_value}"
        log "${_name} loaded from ${_file}"
    fi
}

resolve_secret MYSQL_PASSWORD
resolve_secret REDIS_HOST_PASSWORD
resolve_secret NEXTCLOUD_ADMIN_PASSWORD
resolve_secret OBJECTSTORE_S3_SECRET

for _required in MYSQL_HOST MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD REDIS_HOST REDIS_HOST_PASSWORD; do
    eval "_v=\${${_required}:-}"
    [ -n "${_v}" ] || die "${_required} is not set. See .env.example."
done

# A default-valued admin password is worse than none, because it looks
# configured. Only enforced on first install -- NEXTCLOUD_ADMIN_PASSWORD is
# ignored once the instance exists.
case "${NEXTCLOUD_ADMIN_PASSWORD:-}" in
    admin|password|nextcloud|changeme|CHANGEME|secret)
        die "NEXTCLOUD_ADMIN_PASSWORD is set to a well-known value. Run scripts/gen-secrets.sh."
        ;;
esac

# --- 2. Managed configuration: NOT done here ------------------------------
# Rendering the managed config used to happen at this point, before the
# upstream entrypoint ran. That created /var/www/html/config as root; the
# installer runs as www-data, could not write config.php, and produced an
# instance that started cleanly and reported installed: false forever.
#
# It now runs as a `before-starting` hook, which the upstream entrypoint
# executes after the installation exists and before PHP-FPM starts:
#
#   docker/nextcloud/hooks/before-starting/10-managed-config.sh
#
# The lesson generalises: the upstream image has documented extension points,
# and racing it is how you get failures that look like permissions bugs.

# --- 3. PHP-FPM pool -------------------------------------------------------
# Sizing from the environment so worker count is an operational decision
# rather than an image rebuild.
#
# pm = dynamic, not ondemand: Nextcloud's PHP startup cost is non-trivial and
# ondemand pays it on every idle-to-busy transition, which users experience as
# the first request after a quiet period being slow.
cat > /usr/local/etc/php-fpm.d/zz-nextcloud.conf <<POOL
[www]
pm = dynamic
pm.max_children = ${PHP_FPM_MAX_CHILDREN:-32}
pm.start_servers = ${PHP_FPM_START_SERVERS:-8}
pm.min_spare_servers = ${PHP_FPM_MIN_SPARE_SERVERS:-4}
pm.max_spare_servers = ${PHP_FPM_MAX_SPARE_SERVERS:-12}

; Recycle a worker after this many requests. PHP extensions leak slowly and a
; long-lived worker accumulates it; recycling bounds the damage.
pm.max_requests = 500

; Log a backtrace for any request over 30s. This is what turns "Nextcloud is
; sometimes slow" into a named function.
request_slowlog_timeout = 30s
slowlog = /proc/self/fd/2

; Kill a request still running after 15 minutes. Large uploads and preview
; generation are legitimately slow, so this is generous -- but unbounded means
; one stuck request holds a worker forever.
request_terminate_timeout = 900s

; Expose the FPM status page to nginx on an internal path, for the exporter
; and for diagnosing worker exhaustion.
pm.status_path = /fpm-status
ping.path = /fpm-ping

catch_workers_output = yes
decorate_workers_output = no
clear_env = no
POOL

log "php-fpm pool: max_children=${PHP_FPM_MAX_CHILDREN:-32}"

# --- 4. Hand off -----------------------------------------------------------
# exec so the upstream entrypoint becomes PID 1's child with signals intact.
# Without exec this shell stays PID 1, does not forward SIGTERM, and
# `docker compose down` degrades into a 10-second SIGKILL that can interrupt
# an upgrade mid-migration.
log "chaining to the upstream entrypoint"
exec /entrypoint.sh "$@"
