#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Nextcloud restore.
#
# Restores a backup produced by scripts/backup.sh: the database, the config
# and apps, and the data directory.
#
# THIS IS DESTRUCTIVE. It drops and recreates the database and replaces the
# data directory. It requires a typed confirmation unless --yes is passed,
# because the most likely way to lose data during a recovery is restoring the
# right backup into the wrong environment.
#
#   ./scripts/restore.sh 20260902T054616Z
#   ./scripts/restore.sh 20260902T054616Z --yes       # skip confirmation
#   ./scripts/restore.sh 20260902T054616Z --db-only   # skip the data directory
#
# ORDER MATTERS. Files are restored BEFORE the database.
#
# Nextcloud's oc_filecache holds a row per file. Restoring the database first
# and the files second leaves a window in which Nextcloud is running against
# metadata describing files that are not yet on disk -- and if anything (the
# cron container, a sync client) touches it in that window, Nextcloud marks
# those files as deleted. Restoring files first means the worst case is
# metadata that has not caught up yet, which the following database restore
# fixes.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "${REPO_ROOT}" || exit 1

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 ;;
esac

log()  { printf '\033[0;32m==>\033[0m %s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
warn() { printf '\033[0;33m==> WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

BACKUP_ID=""
ASSUME_YES=0
DB_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)  ASSUME_YES=1; shift ;;
        --db-only) DB_ONLY=1; shift ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        -*)        die "unknown option: $1" ;;
        *)         BACKUP_ID="$1"; shift ;;
    esac
done

[[ -f .env ]] || die ".env not found"
# shellcheck disable=SC1091
set -a; source .env; set +a
: "${MYSQL_USER:?MYSQL_USER must be set}"
: "${MYSQL_DATABASE:=nextcloud}"
: "${BACKUP_DIR:=./backups}"

readonly COMPOSE="docker compose"

db_root() { docker compose exec -e "MYSQL_PWD=${MYSQL_ROOT_PASSWORD}" -T db mariadb -u root "$@"; }
occ()     { docker compose exec --user www-data -T app php occ "$@"; }

if [[ -z "${BACKUP_ID}" ]]; then
    printf 'Available backups in %s:\n\n' "${BACKUP_DIR}"
    find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | sed 's/^/  /'
    printf '\nUsage: %s <backup-id>\n' "$0"
    exit 2
fi

readonly SOURCE="${BACKUP_DIR}/${BACKUP_ID}"
[[ -d "${SOURCE}" ]] || die "no backup at ${SOURCE}"
[[ -f "${SOURCE}/manifest.json" ]] || die "${SOURCE} has no manifest.json -- not a backup from scripts/backup.sh"

# --- Integrity before anything destructive ---------------------------------
# Checksums are verified BEFORE the database is dropped. Discovering a corrupt
# archive after destroying the live data converts a recoverable incident into
# an unrecoverable one.
log "verifying checksums"
if [[ -f "${SOURCE}/SHA256SUMS" ]]; then
    ( cd "${SOURCE}" && sha256sum --quiet -c SHA256SUMS ) \
        || die "checksum mismatch -- this backup is corrupt. Do NOT proceed; try an older backup."
    log "checksums verified"
else
    warn "no SHA256SUMS in this backup; integrity cannot be confirmed"
fi

if compgen -G "${SOURCE}/*.age" > /dev/null; then
    die "this backup is encrypted. Decrypt it first:
      age -d -i <key> -o ${SOURCE}/database.sql.gz ${SOURCE}/database.sql.gz.age
      age -d -i <key> -o ${SOURCE}/data.tar.gz     ${SOURCE}/data.tar.gz.age
      age -d -i <key> -o ${SOURCE}/config.tar.gz   ${SOURCE}/config.tar.gz.age"
fi

[[ -f "${SOURCE}/database.sql.gz" ]] || die "database.sql.gz missing from ${SOURCE}"

# --- Version check ---------------------------------------------------------
# Nextcloud does not support downgrades. Restoring a database written by a
# newer version into older code fails at the schema check, and the failure
# happens after the live database has already been dropped.
backup_version="$(sed -n 's/.*"nextcloud_version": *"\([^"]*\)".*/\1/p' "${SOURCE}/manifest.json" | head -n1)"
current_version="$(occ status 2>/dev/null | grep -oE 'versionstring: [0-9.]+' | awk '{print $2}' || echo unknown)"

if [[ -n "${backup_version}" && "${backup_version}" != "unknown" && "${current_version}" != "unknown" ]]; then
    if [[ "${backup_version}" != "${current_version}" ]]; then
        warn "VERSION MISMATCH"
        warn "  backup was taken from Nextcloud ${backup_version}"
        warn "  this instance is running        ${current_version}"
        warn ""
        warn "  Restoring INTO A NEWER version is supported: run 'occ upgrade' afterwards."
        warn "  Restoring into an OLDER version is NOT -- Nextcloud has no downgrade path,"
        warn "  and the failure happens after the live database is already gone."
        warn "  Pin NEXTCLOUD_VERSION to ${backup_version} in .env first if that is the case."
    fi
fi

backup_created="$(sed -n 's/.*"created_at": *"\([^"]*\)".*/\1/p' "${SOURCE}/manifest.json" | head -n1)"
backup_quiesced="$(sed -n 's/.*"quiesced": *\([a-z]*\).*/\1/p' "${SOURCE}/manifest.json" | head -n1)"

cat <<BANNER

  ------------------------------------------------------------------
   RESTORE
  ------------------------------------------------------------------
   Backup id        ${BACKUP_ID}
   Created          ${backup_created}
   Nextcloud        ${backup_version:-unknown}  (instance: ${current_version})
   Quiesced         ${backup_quiesced:-unknown}
   Into database    ${MYSQL_DATABASE}
   Data directory   $( [[ ${DB_ONLY} -eq 1 ]] && echo "NOT restored" || echo "REPLACED" )
  ------------------------------------------------------------------

   The database '${MYSQL_DATABASE}' will be DROPPED and recreated.
   $( [[ ${DB_ONLY} -eq 1 ]] || echo "The data directory will be REPLACED." )
   Everything currently there will be gone.

BANNER

if [[ "${ASSUME_YES}" -eq 0 ]]; then
    # Typing the database name, not "y". A muscle-memory "y" is exactly how
    # the right backup ends up in the wrong environment.
    printf 'Type the database name to confirm (%s): ' "${MYSQL_DATABASE}"
    read -r confirmation
    [[ "${confirmation}" == "${MYSQL_DATABASE}" ]] || die "confirmation did not match; nothing was changed"
fi

${COMPOSE} ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx db \
    || die "the db service is not running"

# --- Stop the application --------------------------------------------------
# Both app and cron. Leaving cron running during a restore means background
# jobs operating against a half-restored database -- and file scans in that
# state mark real files as deleted.
log "stopping app and cron"
${COMPOSE} stop app cron >/dev/null 2>&1 || true

restart_app() {
    log "starting app and cron"
    ${COMPOSE} start app cron >/dev/null 2>&1 \
        || warn "could not restart -- do it manually: docker compose start app cron"
}
on_exit() {
    local rc=$?
    [[ ${rc} -ne 0 ]] && warn "restore failed (exit ${rc})"
    restart_app
    exit "${rc}"
}
trap on_exit EXIT

# --- 1. Files FIRST --------------------------------------------------------
# See the header: restoring the database first leaves a window in which
# Nextcloud is running against metadata for files that do not exist yet.
if [[ ${DB_ONLY} -eq 1 ]]; then
    warn "--db-only: the data directory is NOT restored."
    warn "  The restored database will reference files that are not on disk."
elif [[ -f "${SOURCE}/data.tar.gz" ]]; then
    log "verifying data archive"
    gzip -t "${SOURCE}/data.tar.gz" || die "data archive fails integrity check"

    log "restoring data directory (this is usually the long step)"
    # The existing data directory is cleared first. Extracting over the top
    # merges the two, leaving files from the pre-restore state that the
    # restored database knows nothing about -- which is how a restore ends up
    # with orphaned files consuming disk that nothing will ever clean up.
    #
    # `run --rm` because the app container is stopped. --entrypoint is
    # overridden: this image's entrypoint renders config and starts FPM.
    ${COMPOSE} run --rm --no-deps --entrypoint sh -T app -c \
        'rm -rf /var/www/html/data/* /var/www/html/data/.[!.]* 2>/dev/null; tar -xzf - -C /var/www/html' \
        < "${SOURCE}/data.tar.gz"

    log "restoring config and apps"
    ${COMPOSE} run --rm --no-deps --entrypoint sh -T app -c \
        'tar -xzf - -C /var/www/html' < "${SOURCE}/config.tar.gz"

    # Ownership matters: files extracted as root cannot be read by the FPM
    # workers, which run as www-data. The symptom is an instance that starts
    # and shows an empty file list.
    ${COMPOSE} run --rm --no-deps --entrypoint sh -T app -c \
        'chown -R www-data:www-data /var/www/html/data /var/www/html/config'

    restored_files="$(${COMPOSE} run --rm --no-deps --entrypoint sh -T app -c \
        'find /var/www/html/data -type f | wc -l' | tr -d '\r')"
    log "  data entries restored: ${restored_files}"
else
    die "data.tar.gz missing but a full restore was requested"
fi

# --- 2. Database -----------------------------------------------------------
log "dropping and recreating '${MYSQL_DATABASE}'"
db_root -e "DROP DATABASE IF EXISTS \`${MYSQL_DATABASE}\`;
            CREATE DATABASE \`${MYSQL_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
            GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
            FLUSH PRIVILEGES;" >/dev/null \
    || die "could not recreate the database"

log "restoring database"
restore_log="${SOURCE}/restore-$(date -u +%Y%m%dT%H%M%SZ).log"
set +e
gzip -dc "${SOURCE}/database.sql.gz" | db_root "${MYSQL_DATABASE}" > "${restore_log}" 2>&1
restore_rc=$?
set -e
[[ ${restore_rc} -eq 0 ]] || { head -10 "${restore_log}" >&2; die "database restore failed; see ${restore_log}"; }

# --- 3. Validate -----------------------------------------------------------
log "validating restored database"
q() { db_root -N -B "${MYSQL_DATABASE}" -e "$1" 2>/dev/null | tr -d '\r'; }

table_count="$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}';")"
log "  tables: ${table_count}"
[[ "${table_count:-0}" -gt 50 ]] || die "only ${table_count} tables restored. Restore FAILED."

for t in oc_users oc_filecache oc_storages oc_appconfig; do
    [[ "$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}' AND table_name='${t}';")" == "1" ]] \
        || die "core table '${t}' is missing. Restore FAILED."
done

user_count="$(q "SELECT count(*) FROM oc_users;")"
file_rows="$(q "SELECT count(*) FROM oc_filecache;")"
log "  users: ${user_count}, filecache rows: ${file_rows}"
[[ "${user_count:-0}" -gt 0 ]] || die "oc_users is empty. Restore FAILED."

# MariaDB has no ANALYZE-equivalent that is as load-bearing as PostgreSQL's,
# but table statistics still matter after a bulk load.
log "updating table statistics"
db_root -e "USE \`${MYSQL_DATABASE}\`; ANALYZE TABLE oc_filecache, oc_users, oc_share;" >/dev/null 2>&1 || true

trap - EXIT
restart_app

# Wait for the app to come back before running occ against it.
log "waiting for the application"
for _ in $(seq 1 30); do
    if occ status >/dev/null 2>&1; then break; fi
    sleep 5
done

# Maintenance mode may have been captured in the backup's config.php if the
# backup ran while the instance was quiesced. Clearing it is idempotent.
occ maintenance:mode --off >/dev/null 2>&1 || true

cat <<DONE

  ------------------------------------------------------------------
   RESTORE COMPLETE
  ------------------------------------------------------------------
   Database         ${MYSQL_DATABASE}
   Tables           ${table_count}
   Users            ${user_count}
   Filecache rows   ${file_rows}
   Data directory   $( [[ ${DB_ONLY} -eq 1 ]] && echo "not restored" || echo "restored" )
  ------------------------------------------------------------------

  Still to do by hand -- none of it is inferable from a backup:

   1. Log in. status.php returning 200 says PHP answered; it does not say
      the application is coherent.
   2. Open a file. This is the only check that catches a database restored
      without its data directory.
   3. If the versions differed, run:  ./scripts/occ.sh upgrade
   4. If anything looks inconsistent:  ./scripts/occ.sh files:scan --all
      That reconciles oc_filecache with what is actually on disk. On a large
      instance it takes a long time, so it is not run automatically.
   5. In a NON-PRODUCTION restore, disable outbound mail and background jobs
      before anyone notices -- otherwise a restored copy starts emailing real
      users about real shares.

DONE
