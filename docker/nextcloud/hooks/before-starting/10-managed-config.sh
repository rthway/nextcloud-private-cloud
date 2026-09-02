#!/bin/sh
# ---------------------------------------------------------------------------
# Render the managed Nextcloud configuration.
#
# This runs as a `before-starting` hook, which the upstream image executes
# after it has populated /var/www/html and completed any install or upgrade,
# and before PHP-FPM starts. That ordering is the whole point.
#
# An earlier version of this repository did the rendering in a custom
# entrypoint that ran BEFORE the upstream one. It created
# /var/www/html/config as root, the installer -- which runs as www-data --
# then could not write config.php, and the result was an instance that
# started, logged "Cannot write into config directory", and reported
# installed: false forever. The container looked healthy to `docker ps` and
# was completely non-functional.
#
# Using the image's documented extension point instead of racing it avoids the
# whole class of problem: by the time this runs, the directory exists with the
# right ownership and Nextcloud is installed.
# ---------------------------------------------------------------------------
set -eu

log() { printf '%s managed-config: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

CONFIG_DIR=/var/www/html/config
TEMPLATE=/usr/local/share/nextcloud/zz-managed.config.php.tmpl
RENDERED="${CONFIG_DIR}/zz-managed.config.php"

[ -f "${TEMPLATE}" ] || { log "no template at ${TEMPLATE}; nothing to do"; exit 0; }
[ -d "${CONFIG_DIR}" ] || { log "FATAL: ${CONFIG_DIR} does not exist"; exit 1; }

# Strict substitution: an unresolved placeholder aborts rather than writing a
# config.php containing a literal ${VAR}, which PHP parses happily into a
# nonsense value that is then very hard to trace.
php -r '
    $tmpl = file_get_contents($argv[1]);
    preg_match_all("/\\$\\{([A-Z0-9_]+)\\}/", $tmpl, $m);
    foreach (array_unique($m[1]) as $key) {
        $val = getenv($key);
        if ($val === false) {
            fwrite(STDERR, "managed-config: FATAL: template references unset variable {$key}\n");
            exit(1);
        }
        $tmpl = str_replace("\${" . $key . "}", $val, $tmpl);
    }
    file_put_contents($argv[2], $tmpl);
' "${TEMPLATE}" "${RENDERED}"

# Owned by www-data and not world-readable. This file carries no credentials
# today -- the upstream fragments hold those -- but config/ as a whole does,
# and a permissive file here would be copied by the next person adding one.
chown www-data:www-data "${RENDERED}"
chmod 640 "${RENDERED}"

# Verify PHP can actually parse what was written. A syntax error here takes
# the whole instance down on the next request with a blank 500, and finding it
# afterwards means reading PHP's error log rather than this one.
if ! php -l "${RENDERED}" >/dev/null 2>&1; then
    log "FATAL: rendered config is not valid PHP"
    php -l "${RENDERED}" >&2 || true
    rm -f "${RENDERED}"
    exit 1
fi

log "rendered and validated ${RENDERED}"
