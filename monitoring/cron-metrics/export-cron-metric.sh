#!/bin/sh
# ---------------------------------------------------------------------------
# Publish Nextcloud's background-job timestamp as a Prometheus metric.
#
# WHY THIS EXISTS
#
# The most valuable Nextcloud-specific alert is "background jobs have
# stopped", because that failure is completely silent. The cron container
# stays up and healthy running its sleep loop while cron.php fails on every
# invocation, and the consequences -- trash never expiring, shares never
# lapsing, file scans never running, the database filling with rows nothing
# cleans up -- take weeks to become visible to anyone.
#
# There is no process-level signal for it. The only evidence is that
# Nextcloud's own `lastcron` value stops advancing.
#
# The serverinfo exporter used elsewhere in this stack does not publish that
# value, so rather than ship an alert referencing a metric nothing produces,
# this writes it into node_exporter's textfile collector directory.
#
# Runs as root so it can own the volume Docker created root:root, and drops to
# www-data for the occ call itself -- occ as root creates root-owned files in
# the data directory that Nextcloud cannot read afterwards, and the symptom
# surfaces later, at the next upload into an affected folder.
# ---------------------------------------------------------------------------
set -eu

TEXTFILE_DIR="${TEXTFILE_DIR:-/textfile}"
INTERVAL="${INTERVAL:-60}"
OCC="${OCC:-/var/www/html/occ}"
readonly OUT="${TEXTFILE_DIR}/nextcloud_cron.prom"
readonly TMP="${TEXTFILE_DIR}/.nextcloud_cron.prom.tmp"

log() { printf '%s cron-metrics: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# Docker creates a named volume owned by root:root, so the unprivileged writer
# cannot create a file in it until this runs.
chown www-data:www-data "${TEXTFILE_DIR}" 2>/dev/null || true

log "publishing to ${OUT} every ${INTERVAL}s"

while true; do
    # `su -s /bin/sh` because www-data's shell is /usr/sbin/nologin in this
    # image, and su honours it. Only the occ call needs to drop privileges;
    # writing the metric file as root is harmless and keeps this simple.
    ts="$(su -s /bin/sh www-data -c "php ${OCC} config:app:get core lastcron" 2>/dev/null || true)"
    ts="$(printf '%s' "${ts}" | tr -d '\r\n[:space:]')"

    # A non-numeric or empty result means occ failed -- the database is down,
    # the instance is mid-upgrade, or the value has never been set. Publishing
    # 0 rather than skipping the write is deliberate: a stale file would let
    # the alert keep reading an old, healthy-looking timestamp long after the
    # application stopped answering.
    case "${ts}" in
        ''|*[!0-9]*) ts=0 ;;
    esac

    # Written to a temporary file and moved into place. node_exporter reads
    # this directory on every scrape, and a half-written file is a parse error
    # that discards EVERY metric in the file, not just this one.
    {
        echo '# HELP nextcloud_last_cron_timestamp_seconds Unix time of the last completed Nextcloud background-job run.'
        echo '# TYPE nextcloud_last_cron_timestamp_seconds gauge'
        echo "nextcloud_last_cron_timestamp_seconds ${ts}"
    } > "${TMP}"
    mv "${TMP}" "${OUT}"

    sleep "${INTERVAL}"
done
