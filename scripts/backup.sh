#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Nextcloud backup.
#
# THREE artefacts, and all three are required for a restore to produce a
# working instance:
#
#   1. the MariaDB database        file metadata, shares, users, app state
#   2. the data directory          the actual file content
#   3. config/ and apps/           config.php, and any app not from the store
#
# The interesting difference from a database-backed application like Odoo is
# that Nextcloud CAN be quiesced. `occ maintenance:mode --on` stops the
# application from accepting writes while leaving it running, so the database
# dump and the file copy describe the same instant.
#
# That is worth taking. Nextcloud's database holds a row per file with its
# size, mtime and checksum; if a file is written between the dump and the
# copy, the restored instance has metadata that does not match the bytes on
# disk. Nextcloud detects the mismatch and the fix is a full `occ files:scan`,
# which on a large instance takes hours.
#
# The cost is a brief outage -- typically the dump duration. Set
# --no-maintenance to skip it and accept the skew.
#
#   ./scripts/backup.sh                  # full, with maintenance mode
#   ./scripts/backup.sh --no-maintenance # no downtime, accepts skew
#   ./scripts/backup.sh --db-only        # faster; NOT a restorable backup
#   ./scripts/backup.sh --no-prune       # keep everything
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "${REPO_ROOT}" || exit 1

PRUNE=1
DB_ONLY=0
MAINTENANCE=1
for arg in "$@"; do
    case "${arg}" in
        --no-prune)       PRUNE=0 ;;
        --db-only)        DB_ONLY=1 ;;
        --no-maintenance) MAINTENANCE=0 ;;
        -h|--help)        sed -n '2,32p' "$0"; exit 0 ;;
        *) printf 'unknown option: %s\n' "${arg}" >&2; exit 2 ;;
    esac
done

[[ -f .env ]] || { printf 'ERROR: .env not found. Run scripts/gen-secrets.sh first.\n' >&2; exit 1; }
# shellcheck disable=SC1091
set -a; source .env; set +a

: "${MYSQL_USER:?MYSQL_USER must be set in .env}"
: "${MYSQL_DATABASE:=nextcloud}"
: "${BACKUP_DIR:=./backups}"
: "${BACKUP_AGE_RECIPIENT:=}"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 ;;
esac

readonly COMPOSE="docker compose"

# MariaDB is reached with an explicit password on every call. Passed per-exec
# rather than set in the service environment so it does not appear in
# `docker inspect` output.
db_exec() { docker compose exec -e "MYSQL_PWD=${MYSQL_PASSWORD}" -T db "$@"; }
occ()     { docker compose exec --user www-data -T app php occ "$@"; }

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
readonly TIMESTAMP
readonly TARGET="${BACKUP_DIR}/${TIMESTAMP}"

log()  { printf '\033[0;32m==>\033[0m %s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
warn() { printf '\033[0;33m==> WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

MAINTENANCE_ON=0

# Two jobs on exit, and the first is the one that matters: an instance left in
# maintenance mode after a failed backup is an outage caused by the backup.
cleanup() {
    local rc=$?

    if [[ ${MAINTENANCE_ON} -eq 1 ]]; then
        log "leaving maintenance mode"
        occ maintenance:mode --off >/dev/null 2>&1 \
            || warn "COULD NOT LEAVE MAINTENANCE MODE. Run: ./scripts/occ.sh maintenance:mode --off"
    fi

    # A partial backup that looks complete is a trap for whoever is restoring
    # at 3am.
    if [[ ${rc} -ne 0 && -d "${TARGET}" ]]; then
        warn "backup failed (exit ${rc}); removing incomplete ${TARGET}"
        rm -rf "${TARGET}"
    fi
    exit ${rc}
}
trap cleanup EXIT

# --- Preflight -------------------------------------------------------------
log "preflight"

${COMPOSE} ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx db \
    || die "the db service is not running; nothing to back up"
${COMPOSE} ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx app \
    || die "the app service is not running"

# Confirm Nextcloud is installed before producing a dump of an empty schema
# that reports success.
if ! occ status 2>/dev/null | grep -q 'installed: true'; then
    die "Nextcloud does not report itself as installed; refusing to back up"
fi

mkdir -p "${TARGET}"
chmod 700 "${TARGET}"

# --- Maintenance mode ------------------------------------------------------
if [[ ${MAINTENANCE} -eq 1 ]]; then
    log "entering maintenance mode (the instance is offline from here)"
    occ maintenance:mode --on >/dev/null || die "could not enter maintenance mode"
    MAINTENANCE_ON=1
    # Let in-flight requests finish. Without this the dump can start while a
    # write transaction is still committing.
    sleep 3
else
    warn "--no-maintenance: the database and files may describe different instants."
    warn "  A restore may need 'occ files:scan --all' to reconcile them."
fi

# --- 1. Database -----------------------------------------------------------
# --single-transaction gives a consistent snapshot of InnoDB tables WITHOUT
# locking them, so it does not block reads. Combined with maintenance mode
# there is nothing writing anyway, but it is correct with or without.
#
# --default-character-set=utf8mb4 matters: dumping as utf8 mangles emoji and
# CJK filenames, and the damage is only visible after the restore.
log "dumping database '${MYSQL_DATABASE}'"

db_exec mariadb-dump \
    --user="${MYSQL_USER}" \
    --single-transaction \
    --quick \
    --default-character-set=utf8mb4 \
    --routines \
    --triggers \
    --events \
    --no-tablespaces \
    "${MYSQL_DATABASE}" \
    2> "${TARGET}/mariadb-dump.log" \
    | gzip -6 > "${TARGET}/database.sql.gz"

[[ -s "${TARGET}/database.sql.gz" ]] || die "mariadb-dump produced an empty file; see ${TARGET}/mariadb-dump.log"

# A gzip stream truncated by a broken pipe still produces a plausible file.
gzip -t "${TARGET}/database.sql.gz" || die "database dump fails gzip integrity check"

db_size="$(wc -c < "${TARGET}/database.sql.gz" | tr -d ' ')"
log "database dump: $(( db_size / 1024 / 1024 )) MiB"

# Structural validation rather than a size check: confirm the dump actually
# contains Nextcloud's core tables. A dump of the wrong database, or one that
# stopped early, passes a size check and fails here.
log "validating dump contents"
core_tables="$(gzip -dc "${TARGET}/database.sql.gz" \
    | grep -cE 'CREATE TABLE `oc_(users|filecache|storages|share|appconfig)`' || true)"
[[ "${core_tables}" -ge 5 ]] \
    || die "dump contains only ${core_tables}/5 core Nextcloud tables -- treat this backup as failed"
log "core tables present: ${core_tables}/5"

# --- 2. Configuration and apps ---------------------------------------------
# config/ holds config.php, which contains the database password -- so this
# archive is as sensitive as the data itself.
#
# apps/ is included because an instance can carry apps that are not in the app
# store: bespoke ones, or versions pinned by hand. Restoring without them
# leaves Nextcloud referencing apps it cannot load.
log "archiving configuration and apps"
${COMPOSE} exec -T app tar -cf - -C /var/www/html config apps themes 2>/dev/null \
    | gzip -6 > "${TARGET}/config.tar.gz"

[[ -s "${TARGET}/config.tar.gz" ]] || die "configuration archive is empty"
gzip -t "${TARGET}/config.tar.gz" || die "configuration archive fails integrity check"

# --- 3. Data ---------------------------------------------------------------
if [[ ${DB_ONLY} -eq 1 ]]; then
    warn "--db-only: user files NOT included. This is not a restorable backup."
    data_size=0
    data_files=0
elif [[ -n "${OBJECTSTORE_S3_BUCKET:-}" ]]; then
    # With S3 as primary storage, file CONTENT is not on this volume at all --
    # only Nextcloud's appdata and previews are. Backing up the local
    # directory would produce an archive that looks reasonable and restores an
    # instance with no user files.
    warn "object storage is configured (${OBJECTSTORE_S3_BUCKET})."
    warn "  User file content lives in the bucket, NOT in this archive."
    warn "  The bucket needs its own backup -- versioning plus replication."
    warn "  See BACKUP-RESTORE.md, 'Backing up object storage'."
    log "archiving local data directory (appdata and previews only)"
    ${COMPOSE} exec -T app tar -cf - -C /var/www/html data 2>/dev/null \
        | gzip -6 > "${TARGET}/data.tar.gz"
    data_size="$(wc -c < "${TARGET}/data.tar.gz" | tr -d ' ')"
    data_files="$(tar -tzf "${TARGET}/data.tar.gz" | wc -l | tr -d ' ')"
else
    log "archiving data directory"
    # Streamed to the host and compressed here: it keeps compression tooling
    # out of the image and avoids writing a large temporary file into the
    # container's writable layer, which is the one filesystem not on a volume.
    ${COMPOSE} exec -T app tar -cf - -C /var/www/html data 2>/dev/null \
        | gzip -6 > "${TARGET}/data.tar.gz"

    [[ -s "${TARGET}/data.tar.gz" ]] || die "data archive is empty"
    gzip -t "${TARGET}/data.tar.gz" || die "data archive fails gzip integrity check"

    data_size="$(wc -c < "${TARGET}/data.tar.gz" | tr -d ' ')"
    data_files="$(tar -tzf "${TARGET}/data.tar.gz" | wc -l | tr -d ' ')"
    log "data archive: $(( data_size / 1024 / 1024 )) MiB, ${data_files} entries"
fi

# --- Leave maintenance mode early -----------------------------------------
# Everything below reads only the artefacts already written, so the instance
# can come back now rather than after checksums and encryption.
if [[ ${MAINTENANCE_ON} -eq 1 ]]; then
    log "leaving maintenance mode (the instance is back online)"
    occ maintenance:mode --off >/dev/null || warn "could not leave maintenance mode"
    MAINTENANCE_ON=0
fi

# --- Metadata --------------------------------------------------------------
log "recording instance state"
{
    echo "# Nextcloud status at backup time. A restore must go back to the SAME"
    echo "# version -- Nextcloud does not support downgrades, and restoring a"
    echo "# database from a newer version into older code fails at schema check."
    occ status 2>/dev/null || true
    echo
    echo "# Enabled apps. Restoring the database without these leaves Nextcloud"
    echo "# referencing apps it cannot load."
    occ app:list 2>/dev/null || true
} > "${TARGET}/instance-state.txt" 2>/dev/null || warn "could not record instance state"

nc_version="$(grep -oE 'version: [0-9.]+' "${TARGET}/instance-state.txt" 2>/dev/null | head -1 | awk '{print $2}' || echo unknown)"

log "computing checksums"
(
    cd "${TARGET}"
    find . -maxdepth 1 -type f ! -name 'SHA256SUMS' ! -name 'manifest.json' -print0 \
        | sort -z | xargs -0 sha256sum > SHA256SUMS
)

db_sha="$(awk '/database\.sql\.gz$/ {print $1}' "${TARGET}/SHA256SUMS")"
data_sha="$(awk '/data\.tar\.gz$/ {print $1}' "${TARGET}/SHA256SUMS" || true)"

cat > "${TARGET}/manifest.json" <<MANIFEST
{
  "schema_version": 1,
  "backup_id": "${TIMESTAMP}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "created_by": "scripts/backup.sh",
  "hostname": "$(hostname)",
  "type": "$( [[ ${DB_ONLY} -eq 1 ]] && echo database-only || echo full )",
  "quiesced": $( [[ ${MAINTENANCE} -eq 1 ]] && echo true || echo false ),
  "nextcloud_version": "${nc_version}",
  "database": {
    "name": "${MYSQL_DATABASE}",
    "engine": "mariadb",
    "format": "mariadb-dump --single-transaction, gzip",
    "bytes": ${db_size},
    "sha256": "${db_sha}",
    "core_tables_found": ${core_tables}
  },
  "data": {
    "included": $( [[ ${DB_ONLY} -eq 1 ]] && echo false || echo true ),
    "object_storage": $( [[ -n "${OBJECTSTORE_S3_BUCKET:-}" ]] && echo true || echo false ),
    "bytes": ${data_size},
    "entries": ${data_files},
    "sha256": "${data_sha:-null}"
  },
  "encrypted": $( [[ -n "${BACKUP_AGE_RECIPIENT}" ]] && echo true || echo false ),
  "restore_command": "./scripts/restore.sh ${TIMESTAMP}",
  "verified": false
}
MANIFEST

# --- Encryption ------------------------------------------------------------
# These archives contain every user's files and the database password.
if [[ -n "${BACKUP_AGE_RECIPIENT}" ]]; then
    if command -v age >/dev/null 2>&1; then
        log "encrypting artefacts to ${BACKUP_AGE_RECIPIENT}"
        for artefact in database.sql.gz data.tar.gz config.tar.gz; do
            [[ -f "${TARGET}/${artefact}" ]] || continue
            age -r "${BACKUP_AGE_RECIPIENT}" -o "${TARGET}/${artefact}.age" "${TARGET}/${artefact}"
            rm -f "${TARGET}/${artefact}"
        done
        log "artefacts encrypted; plaintext removed"
    else
        # Deliberately fatal. Silently writing an unencrypted backup when the
        # operator asked for encryption is a failure discovered only by
        # whoever finds the backup.
        die "BACKUP_AGE_RECIPIENT is set but 'age' is not installed. Refusing to write an unencrypted backup."
    fi
else
    warn "BACKUP_AGE_RECIPIENT is unset: this backup is NOT encrypted, and it contains"
    warn "  every user's files as well as the database password from config.php."
fi

# --- Retention -------------------------------------------------------------
if [[ "${PRUNE}" -eq 1 ]]; then
    log "applying retention policy"
    "${REPO_ROOT}/scripts/prune-backups.sh" || warn "retention pass failed; backups were NOT pruned"
fi

trap - EXIT

total="$(du -sh "${TARGET}" | cut -f1)"
log "backup complete: ${TARGET} (${total})"

cat <<SUMMARY

  A backup that has never been restored is a hypothesis, not a backup.

  Verify this one:      ./scripts/verify-backup.sh ${TIMESTAMP}
  Restore from it:      ./scripts/restore.sh ${TIMESTAMP}

SUMMARY
