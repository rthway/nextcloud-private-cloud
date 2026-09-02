#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Backup verification.
#
# The step almost every backup strategy is missing. A job that reports success
# proves a file was written; it proves nothing about whether that file can
# become a working system. The gap between those two is where organisations
# discover, during an outage, that they have been archiving corrupt dumps for
# months.
#
# This restores the database into a throwaway schema ALONGSIDE the live one,
# interrogates it, cross-references it against the data archive, and drops it.
# The live database, the live data directory and the running instance are
# never touched. Safe to run against production, and intended to.
#
#   ./scripts/verify-backup.sh                    # newest backup
#   ./scripts/verify-backup.sh 20260902T054616Z   # a specific one
#   ./scripts/verify-backup.sh --keep             # leave the scratch schema
#
# Exit 0 means this backup was restored and passed every check.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "${REPO_ROOT}" || exit 1

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 ;;
esac

log()  { printf '\033[0;32m==>\033[0m %s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$*"; FAILURES=$(( FAILURES + 1 )); }
warn() { printf '\033[0;33m==> WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

BACKUP_ID=""
KEEP=0
for arg in "$@"; do
    case "${arg}" in
        --keep) KEEP=1 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) BACKUP_ID="${arg}" ;;
    esac
done

[[ -f .env ]] || die ".env not found"
# shellcheck disable=SC1091
set -a; source .env; set +a
: "${MYSQL_USER:?MYSQL_USER must be set}"
: "${MYSQL_DATABASE:=nextcloud}"
: "${BACKUP_DIR:=./backups}"

readonly COMPOSE="docker compose"
FAILURES=0

# root is needed to CREATE and DROP a database; the application user has
# rights only on its own schema. MYSQL_PWD is passed per-exec so it does not
# appear in `docker inspect`.
db_root() { docker compose exec -e "MYSQL_PWD=${MYSQL_ROOT_PASSWORD}" -T db mariadb -u root "$@"; }

if [[ -z "${BACKUP_ID}" ]]; then
    BACKUP_ID="$(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -n1)"
    [[ -n "${BACKUP_ID}" ]] || die "no backups found in ${BACKUP_DIR}"
    log "no backup specified; using the newest: ${BACKUP_ID}"
fi

readonly SOURCE="${BACKUP_DIR}/${BACKUP_ID}"
[[ -d "${SOURCE}" ]] || die "no backup at ${SOURCE}"

# A scratch name that cannot collide with anything real and is obviously
# disposable to whoever finds it in SHOW DATABASES during an investigation.
# MariaDB identifiers cannot contain a hyphen unquoted, so the timestamp is
# lowercased and stripped.
SCRATCH_DB="verify_$(printf '%s' "${BACKUP_ID}" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
readonly SCRATCH_DB

started_at="$(date -u +%s)"

cat <<BANNER

  ------------------------------------------------------------------
   BACKUP VERIFICATION
  ------------------------------------------------------------------
   Backup           ${BACKUP_ID}
   Scratch schema   ${SCRATCH_DB}
   Live database    ${MYSQL_DATABASE}  (not touched)
  ------------------------------------------------------------------

BANNER

cleanup() {
    if [[ ${KEEP} -eq 1 ]]; then
        warn "--keep: leaving ${SCRATCH_DB} in place. Drop it when done:"
        warn "  docker compose exec -T db mariadb -u root -p -e 'DROP DATABASE \`${SCRATCH_DB}\`;'"
        return
    fi
    log "dropping scratch schema"
    db_root -e "DROP DATABASE IF EXISTS \`${SCRATCH_DB}\`;" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 1. Artefact integrity -------------------------------------------------
log "1/5  artefact integrity"

[[ -f "${SOURCE}/manifest.json" ]] && pass "manifest.json present" || fail "manifest.json missing"

if [[ -f "${SOURCE}/SHA256SUMS" ]]; then
    if ( cd "${SOURCE}" && sha256sum --quiet -c SHA256SUMS ) 2>/dev/null; then
        pass "checksums match"
    else
        fail "CHECKSUM MISMATCH -- this backup is corrupt"
    fi
else
    fail "SHA256SUMS missing; integrity cannot be confirmed"
fi

if compgen -G "${SOURCE}/*.age" > /dev/null; then
    die "this backup is encrypted. Decrypt it first -- see BACKUP-RESTORE.md."
fi

[[ -f "${SOURCE}/database.sql.gz" ]] || die "database.sql.gz missing -- nothing to verify"
gzip -t "${SOURCE}/database.sql.gz" 2>/dev/null \
    && pass "database dump readable ($(du -h "${SOURCE}/database.sql.gz" | cut -f1))" \
    || fail "database dump fails gzip integrity check"

if [[ -f "${SOURCE}/data.tar.gz" ]]; then
    gzip -t "${SOURCE}/data.tar.gz" 2>/dev/null \
        && pass "data archive readable ($(du -h "${SOURCE}/data.tar.gz" | cut -f1))" \
        || fail "data archive fails gzip integrity check"
else
    warn "no data archive -- this is a database-only backup"
fi

if [[ -f "${SOURCE}/config.tar.gz" ]]; then
    # config.php is not optional: without it a restored instance has no
    # database credentials, no instanceid and no passwordsalt -- and a wrong
    # passwordsalt invalidates every stored password.
    #
    # The listing is captured into a variable rather than piped into `grep -q`.
    # `grep -q` exits as soon as it matches, which sends SIGPIPE to tar; under
    # `set -o pipefail` the pipeline then reports tar's 141 and the check fails
    # on an archive that plainly contains the file. It is a genuinely
    # confusing bug -- the two later checks below extract the same file from
    # the same archive successfully, because tar finishes before grep exits
    # when only one small member is being read.
    config_listing="$(tar -tzf "${SOURCE}/config.tar.gz" 2>/dev/null || true)"
    if grep -qF 'config/config.php' <<<"${config_listing}"; then
        pass "config archive contains config.php"
    else
        fail "config archive does NOT contain config.php -- a restore would have no credentials"
    fi
else
    fail "config.tar.gz missing"
fi

# --- 2. Restore into scratch ----------------------------------------------
log "2/5  restoring into ${SCRATCH_DB}"

${COMPOSE} ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx db \
    || die "the db service is not running"

db_root -e "DROP DATABASE IF EXISTS \`${SCRATCH_DB}\`;
            CREATE DATABASE \`${SCRATCH_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" >/dev/null \
    || die "could not create the scratch schema"

restore_start="$(date -u +%s)"
set +e
gzip -dc "${SOURCE}/database.sql.gz" | db_root "${SCRATCH_DB}" > /tmp/nc-verify-restore.log 2>&1
restore_rc=$?
set -e
restore_seconds=$(( $(date -u +%s) - restore_start ))

if [[ ${restore_rc} -eq 0 ]]; then
    pass "restore completed in ${restore_seconds}s"
else
    fail "restore exited ${restore_rc} after ${restore_seconds}s; see /tmp/nc-verify-restore.log"
    head -5 /tmp/nc-verify-restore.log | sed 's/^/          /'
fi

q() { db_root -N -B "${SCRATCH_DB}" -e "$1" 2>/dev/null | tr -d '\r'; }

# --- 3. Schema -------------------------------------------------------------
log "3/5  schema"

table_count="$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema='${SCRATCH_DB}';")"
if [[ "${table_count:-0}" -gt 50 ]]; then
    pass "${table_count} tables restored"
else
    fail "only ${table_count:-0} tables -- a Nextcloud schema has well over 50"
fi

for t in oc_users oc_filecache oc_storages oc_share oc_appconfig oc_jobs oc_authtoken; do
    if [[ "$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema='${SCRATCH_DB}' AND table_name='${t}';")" == "1" ]]; then
        pass "core table ${t}"
    else
        fail "core table ${t} MISSING"
    fi
done

index_count="$(q "SELECT count(DISTINCT index_name) FROM information_schema.statistics WHERE table_schema='${SCRATCH_DB}';")"
if [[ "${index_count:-0}" -gt 50 ]]; then
    pass "${index_count} indexes restored"
else
    fail "only ${index_count:-0} indexes -- the restore may have stopped early"
fi

# --- 4. Data ---------------------------------------------------------------
log "4/5  data"

user_count="$(q "SELECT count(*) FROM oc_users;")"
[[ "${user_count:-0}" -gt 0 ]] && pass "${user_count} users" || fail "oc_users is empty"

# A user row with an empty password hash cannot log in. That is a restore that
# looks complete and locks everyone out.
bad_hashes="$(q "SELECT count(*) FROM oc_users WHERE password IS NULL OR password = '';")"
[[ "${bad_hashes:-0}" -eq 0 ]] && pass "every user has a password hash" \
    || fail "${bad_hashes} user(s) have no password hash"

file_rows="$(q "SELECT count(*) FROM oc_filecache;")"
[[ "${file_rows:-0}" -gt 0 ]] && pass "${file_rows} filecache rows" || fail "oc_filecache is empty"

storage_count="$(q "SELECT count(*) FROM oc_storages;")"
[[ "${storage_count:-0}" -gt 0 ]] && pass "${storage_count} storages" || fail "oc_storages is empty"

app_count="$(q "SELECT count(DISTINCT appid) FROM oc_appconfig;")"
[[ "${app_count:-0}" -gt 0 ]] && pass "${app_count} apps configured" || fail "oc_appconfig is empty"

# The instance id and password salt live in config.php, not the database --
# but losing them makes the database useless, so their presence in the config
# archive is checked here where it will be noticed.
if tar -xzOf "${SOURCE}/config.tar.gz" config/config.php 2>/dev/null | grep -q "'passwordsalt'"; then
    pass "config.php carries passwordsalt (without it, every password breaks)"
else
    fail "config.php has no passwordsalt -- a restore would invalidate every password"
fi
if tar -xzOf "${SOURCE}/config.tar.gz" config/config.php 2>/dev/null | grep -q "'instanceid'"; then
    pass "config.php carries instanceid"
else
    fail "config.php has no instanceid"
fi

# --- 5. Database-to-files cross-check --------------------------------------
# The check that makes this a real verification rather than a database one.
#
# oc_filecache holds a row per file Nextcloud believes exists. If the database
# says there are thousands of files and the archive holds a handful, the
# backup is internally inconsistent -- and the restored instance would show
# users files that are not there.
log "5/5  database-to-files cross-check"

if [[ -f "${SOURCE}/data.tar.gz" ]]; then
    if grep -q '"object_storage": true' "${SOURCE}/manifest.json" 2>/dev/null; then
        warn "object storage is in use: file CONTENT is in the bucket, not this archive."
        warn "  The bucket needs its own verification -- see BACKUP-RESTORE.md."
        pass "cross-check skipped (object storage), and said so"
    else
        # Files belonging to a user, excluding directories and Nextcloud's own
        # appdata/previews which are regenerable.
        db_files="$(q "SELECT count(*) FROM oc_filecache
                       WHERE mimetype != (SELECT id FROM oc_mimetypes WHERE mimetype='httpd/unix-directory')
                         AND path LIKE 'files/%';")"
        # grep -c reads to EOF, so unlike grep -q it does not SIGPIPE the
        # producer under pipefail. Kept as a pipe deliberately: the data
        # listing can be very large and buffering it into a variable is
        # wasteful when only a count is needed.
        archive_files="$(tar -tzf "${SOURCE}/data.tar.gz" 2>/dev/null | grep -c '/files/.*[^/]$' || true)"

        printf '  database references %s user file(s); archive contains %s\n' \
            "${db_files:-0}" "${archive_files:-0}"

        if [[ "${db_files:-0}" -eq 0 ]]; then
            pass "no user files to cross-check"
        elif [[ "${archive_files:-0}" -ge "${db_files:-0}" ]]; then
            # The archive may hold MORE than the database references: the
            # backup is taken under maintenance mode, but trashbin and version
            # files also live under files_trashbin/ and files_versions/.
            pass "archive covers every referenced file (${archive_files} >= ${db_files})"
        else
            fail "archive is missing files the database references (${archive_files} < ${db_files}) -- users would see broken files"
        fi
    fi
else
    warn "no data archive to cross-check"
fi

# --- Result ----------------------------------------------------------------
elapsed=$(( $(date -u +%s) - started_at ))
echo

if [[ ${FAILURES} -eq 0 ]]; then
    if [[ -f "${SOURCE}/manifest.json" ]]; then
        tmp="$(mktemp)"
        sed "s/\"verified\": false/\"verified\": true, \"verified_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"restore_seconds\": ${restore_seconds}/" \
            "${SOURCE}/manifest.json" > "${tmp}" && mv "${tmp}" "${SOURCE}/manifest.json"
    fi
    cat <<RESULT
  ------------------------------------------------------------------
   VERIFIED -- backup ${BACKUP_ID} is restorable
  ------------------------------------------------------------------
   Database restore   ${restore_seconds}s   (evidence for the RTO in
                                             DISASTER-RECOVERY.md)
   Total elapsed      ${elapsed}s
  ------------------------------------------------------------------

RESULT
    exit 0
else
    cat <<RESULT
  ------------------------------------------------------------------
   FAILED -- ${FAILURES} check(s) did not pass
  ------------------------------------------------------------------

   Do not rely on backup ${BACKUP_ID}.
   Verify the next-oldest, then work out when the failure started:
   docs/runbooks/backup-failed.md

RESULT
    exit 1
fi
