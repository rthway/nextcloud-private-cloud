#!/bin/sh
# ---------------------------------------------------------------------------
# Container healthcheck for PHP-FPM.
#
# PHP-FPM speaks FastCGI, not HTTP, so there is no URL to curl. Two checks,
# because either alone gives a false pass:
#
#   1. FPM's own ping endpoint, via cgi-fcgi -- proves the master is alive and
#      a worker answered.
#   2. Nextcloud's status.php rendered through the PHP CLI -- proves the
#      application can reach its database and is not stuck in maintenance
#      mode or a half-finished upgrade.
#
# Check 1 alone passes while Nextcloud is completely broken. Check 2 alone
# passes while FPM has no free workers.
# ---------------------------------------------------------------------------
set -eu

# --- 1. Is FPM answering? --------------------------------------------------
if command -v cgi-fcgi >/dev/null 2>&1; then
    SCRIPT_NAME=/fpm-ping \
    SCRIPT_FILENAME=/fpm-ping \
    REQUEST_METHOD=GET \
    cgi-fcgi -bind -connect 127.0.0.1:9000 >/dev/null 2>&1 \
        || { echo "unhealthy: php-fpm did not answer on 127.0.0.1:9000"; exit 1; }
else
    # Verified: cgi-fcgi is NOT in nextcloud:34.0.3-fpm-alpine. This is the
    # path that actually runs. A TCP probe is weaker -- it proves the listener
    # is open, not that a worker is free -- but installing an FastCGI client
    # solely for a healthcheck means owning another package and its CVEs.
    #
    # Check 2 below is what carries the weight, and it exercises the whole
    # application including its database connection. Worker exhaustion is
    # monitored separately from the FPM status page, which is the right tool
    # for it.
    nc -z 127.0.0.1 9000 2>/dev/null \
        || { echo "unhealthy: nothing listening on 9000"; exit 1; }
fi

# --- 2. Is Nextcloud itself healthy? ---------------------------------------
# Before installation status.php does not exist; that is a legitimate state
# during the start period, not a failure.
[ -f /var/www/html/status.php ] || exit 0

# NOTE ON THE OUTPUT FORMAT
#
# status.php returns JSON when fetched over HTTP, but run through the PHP CLI
# it prints a print_r() array:
#
#   Array
#   (
#       [installed] => 1
#       [maintenance] =>
#       [version] => 34.0.3.2
#   )
#
# An earlier version of this script grepped for '"installed":true' and
# therefore failed on a perfectly healthy instance. Booleans render as 1 or as
# the empty string, so the check is for `[installed] => 1` specifically.
status="$(php -f /var/www/html/status.php 2>/dev/null || true)"

[ -n "${status}" ] || { echo "unhealthy: status.php produced no output"; exit 1; }

if ! printf '%s' "${status}" | grep -qE '\[installed\] *=> *1'; then
    echo "unhealthy: Nextcloud reports installed = false"
    printf '%s
' "${status}" | tr -d '
'
    exit 1
fi

# Maintenance mode is deliberate during a backup or an upgrade, so it is
# reported rather than failed. A healthcheck that failed here would restart
# the container mid-dump, which is how a backup corrupts an instance.
if printf '%s' "${status}" | grep -qE '\[maintenance\] *=> *1'; then
    echo "in maintenance mode (reported, not failed)"
    exit 0
fi

# needsDbUpgrade means an image was replaced without the upgrade having run.
# Nextcloud refuses most requests in this state, so it is a genuine failure.
if printf '%s' "${status}" | grep -qE '\[needsDbUpgrade\] *=> *1'; then
    echo "unhealthy: database upgrade pending -- run: ./scripts/occ.sh upgrade"
    exit 1
fi

exit 0
