#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Stack health check.
#
# Answers "is this deployment actually working", which is a different question
# from "are the containers running". A container can be up, healthy by its own
# reckoning, and serving 500s because its database has filled the disk.
#
# Written to be the first thing an operator runs when something is reported
# wrong, and safe to run at any time -- it reads, it never writes.
#
#   ./scripts/healthcheck.sh            # human-readable
#   ./scripts/healthcheck.sh --quiet    # exit code only, for cron and CI
#
# Exit 0 all checks passed / 1 one or more failed.
# ---------------------------------------------------------------------------
# Deliberately not -e: every check must run, not just those before the first
# failure. An operator wants the whole picture, not the first symptom.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "${REPO_ROOT}" || exit 1

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 ;;
esac

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

FAILURES=0
WARNINGS=0

head_() { [[ ${QUIET} -eq 1 ]] || printf '\n\033[1m%s\033[0m\n' "$*"; }
pass()  { [[ ${QUIET} -eq 1 ]] || printf '  \033[0;32mOK\033[0m    %s\n' "$*"; }
warn()  { [[ ${QUIET} -eq 1 ]] || printf '  \033[0;33mWARN\033[0m  %s\n' "$*"; WARNINGS=$(( WARNINGS + 1 )); }
fail()  { [[ ${QUIET} -eq 1 ]] || printf '  \033[0;31mFAIL\033[0m  %s\n' "$*"; FAILURES=$(( FAILURES + 1 )); }

if [[ -f .env ]]; then
    # shellcheck disable=SC1091
    set -a; source .env; set +a
fi
: "${MYSQL_USER:=nextcloud}"
: "${MYSQL_DATABASE:=nextcloud}"
: "${MYSQL_PASSWORD:=}"
: "${MYSQL_ROOT_PASSWORD:=}"
: "${REDIS_PASSWORD:=}"
: "${NEXTCLOUD_DOMAIN:=nextcloud.localhost}"
: "${BACKUP_DIR:=./backups}"

readonly COMPOSE="docker compose"

db_root()  { docker compose exec -e "MYSQL_PWD=${MYSQL_ROOT_PASSWORD}" -T db mariadb -u root "$@"; }
redis_cli() { docker compose exec -T redis redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning "$@"; }
occ()      { docker compose exec --user www-data -T app php occ "$@"; }

# --- 1. Containers ---------------------------------------------------------
head_ "Containers"

for svc in db redis app cron proxy; do
    state="$(${COMPOSE} ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk -v s="${svc}" '$1==s {print $2}')"
    if [[ -z "${state}" ]]; then fail "${svc}: not present"; continue; fi
    if [[ "${state}" != "running" ]]; then fail "${svc}: ${state}"; continue; fi

    cid="$(${COMPOSE} ps -q "${svc}" 2>/dev/null)"
    # Compose reports State=running for a container whose healthcheck is
    # failing, so health has to be read separately. That gap between "up" and
    # "working" is the whole reason this script exists.
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null)"
    case "${health}" in
        healthy)  pass "${svc}: running, healthy" ;;
        none)     pass "${svc}: running (no healthcheck by design)" ;;
        starting) warn "${svc}: running, health check still starting" ;;
        *)        fail "${svc}: running but ${health}" ;;
    esac

    restarts="$(docker inspect --format '{{.RestartCount}}' "${cid}" 2>/dev/null || echo 0)"
    [[ "${restarts}" -gt 3 ]] && warn "${svc}: has restarted ${restarts} times -- check for a crash loop"
done

# --- 2. Nextcloud ----------------------------------------------------------
head_ "Nextcloud"

status="$(occ status 2>/dev/null | tr -d '\r')"
if [[ -z "${status}" ]]; then
    fail "occ produced no output -- the application is not answering"
else
    if grep -q 'installed: true' <<<"${status}"; then
        pass "installed, version $(grep -oE 'versionstring: [0-9.]+' <<<"${status}" | awk '{print $2}')"
    else
        fail "Nextcloud reports installed: false"
    fi

    if grep -q 'maintenance: true' <<<"${status}"; then
        # Deliberate during a backup or upgrade -- but a stuck maintenance
        # mode is an outage, and a failed backup is exactly how one happens.
        warn "MAINTENANCE MODE IS ON. If no backup or upgrade is running:"
        warn "  ./scripts/occ.sh maintenance:mode --off"
    else
        pass "not in maintenance mode"
    fi

    if grep -q 'needsDbUpgrade: true' <<<"${status}"; then
        fail "database upgrade pending -- run: ./scripts/occ.sh upgrade"
    else
        pass "no pending database upgrade"
    fi
fi

# Background jobs. The single most consequential misconfiguration in a
# self-hosted Nextcloud, and it degrades silently.
bgmode="$(occ config:system:get backgroundjobs_mode 2>/dev/null | tr -d '\r')"
if [[ "${bgmode}" == "cron" ]]; then
    pass "background jobs mode: cron"
else
    fail "background jobs mode is '${bgmode:-unset}', expected 'cron' -- scheduled work is not running reliably"
fi

# When cron last actually ran. A cron container that is up but whose cron.php
# fails every run leaves this frozen, and nothing else would show it.
lastcron="$(occ config:app:get core lastcron 2>/dev/null | tr -d '\r')"
if [[ -n "${lastcron}" && "${lastcron}" =~ ^[0-9]+$ ]]; then
    age=$(( $(date +%s) - lastcron ))
    if   [[ ${age} -gt 3600 ]]; then fail "background jobs last ran $(( age / 60 )) minutes ago -- cron is not working"
    elif [[ ${age} -gt 900 ]];  then warn "background jobs last ran $(( age / 60 )) minutes ago"
    else                             pass "background jobs last ran $(( age / 60 )) minute(s) ago"
    fi
else
    warn "cannot determine when background jobs last ran"
fi

# --- 3. Caching and locking ------------------------------------------------
head_ "Caching and file locking"

locking="$(occ config:system:get memcache.locking 2>/dev/null | tr -d '\r')"
if [[ "${locking}" == *"Redis"* ]]; then
    pass "file locking via Redis"
else
    # Without Redis locking, concurrent access to the same file produces
    # "file is locked" errors that users report as corruption.
    fail "memcache.locking is '${locking:-unset}', expected Redis"
fi

localcache="$(occ config:system:get memcache.local 2>/dev/null | tr -d '\r')"
[[ "${localcache}" == *"APCu"* ]] && pass "local cache via APCu" \
    || warn "memcache.local is '${localcache:-unset}', expected APCu"

if redis_cli ping 2>/dev/null | grep -q PONG; then
    keys="$(redis_cli dbsize 2>/dev/null | tr -d '\r')"
    pass "Redis responding (${keys} keys)"

    # If Redis is evicting, it may be evicting locks -- which is why
    # maxmemory-policy is volatile-lru rather than allkeys-lru.
    evicted="$(redis_cli info stats 2>/dev/null | grep -oE 'evicted_keys:[0-9]+' | cut -d: -f2 | tr -d '\r')"
    if [[ "${evicted:-0}" -gt 0 ]]; then
        warn "Redis has evicted ${evicted} keys -- check maxmemory against actual usage"
    else
        pass "Redis has evicted nothing"
    fi
else
    fail "Redis is not responding"
fi

# --- 4. Database -----------------------------------------------------------
head_ "MariaDB"

if db_root -e "SELECT 1;" >/dev/null 2>&1; then
    pass "accepting connections"

    q() { db_root -N -B -e "$1" 2>/dev/null | tr -d '\r'; }

    size="$(q "SELECT ROUND(SUM(data_length + index_length)/1024/1024) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}';")"
    pass "database size: ${size:-?} MB"

    used="$(q "SELECT COUNT(*) FROM information_schema.processlist;")"
    limit="$(q "SELECT @@max_connections;")"
    if [[ -n "${used}" && -n "${limit}" ]]; then
        pct=$(( used * 100 / limit ))
        if   [[ ${pct} -ge 90 ]]; then fail "connections ${used}/${limit} (${pct}%) -- exhaustion imminent"
        elif [[ ${pct} -ge 75 ]]; then warn "connections ${used}/${limit} (${pct}%)"
        else                           pass "connections ${used}/${limit} (${pct}%)"
        fi
    fi

    # These two must not drift: Nextcloud deadlocks under REPEATABLE-READ, and
    # utf8mb3 cannot store emoji or many CJK characters in filenames.
    iso="$(q "SELECT @@transaction_isolation;")"
    [[ "${iso}" == "READ-COMMITTED" ]] && pass "transaction isolation: READ-COMMITTED" \
        || fail "transaction isolation is '${iso}', expected READ-COMMITTED"

    charset="$(q "SELECT default_character_set_name FROM information_schema.schemata WHERE schema_name='${MYSQL_DATABASE}';")"
    [[ "${charset}" == "utf8mb4" ]] && pass "character set: utf8mb4" \
        || fail "character set is '${charset}', expected utf8mb4"

    # A long-running transaction holds locks and blocks every writer behind it.
    long_txn="$(q "SELECT COUNT(*) FROM information_schema.innodb_trx WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 60;" 2>/dev/null)"
    [[ "${long_txn:-0}" -eq 0 ]] && pass "no transactions older than 60s" \
        || warn "${long_txn} transaction(s) running longer than 60s"
else
    fail "MariaDB is not accepting connections"
fi

# --- 5. HTTP ---------------------------------------------------------------
head_ "HTTP"

# Probed from inside the app container so this needs no tooling on the host
# and exercises the real proxy path. Certificate verification is off here on
# purpose: the certificate is checked separately below against the file, and
# conflating the two makes a local self-signed certificate look like an outage.
http_probe() {
    docker compose exec -T app php -r '
        $ctx = stream_context_create([
            "ssl"  => ["verify_peer" => false, "verify_peer_name" => false],
            "http" => ["header" => "Host: '"${NEXTCLOUD_DOMAIN}"'", "timeout" => 10,
                       "ignore_errors" => true, "follow_location" => 0],
        ]);
        $body = @file_get_contents("https://proxy'"$1"'", false, $ctx);
        if (!isset($http_response_header[0])) { echo "000"; exit; }
        preg_match("#HTTP/\S+ (\d{3})#", $http_response_header[0], $m);
        echo $m[1] ?? "000";
    ' 2>/dev/null | tr -d '\r'
}

code="$(http_probe /status.php)"
[[ "${code}" == "200" ]] && pass "https //${NEXTCLOUD_DOMAIN}/status.php -> 200 (through the proxy)" \
    || fail "status.php through the proxy -> ${code}"

code="$(http_probe /login)"
[[ "${code}" == "200" ]] && pass "/login -> 200" || fail "/login -> ${code}"

# Sensitive paths must not be served. A regression here leaks config.php,
# which contains the database password.
for p in /config/config.php /data/.ocdata /lib/base.php; do
    code="$(http_probe "${p}")"
    [[ "${code}" == "404" ]] && pass "${p} blocked (404)" || fail "${p} returned ${code}; must be 404"
done

# --- 6. TLS ----------------------------------------------------------------
head_ "TLS"

cert="config/nginx/tls/fullchain.pem"
if [[ -f "${cert}" ]]; then
    if not_after="$(openssl x509 -in "${cert}" -noout -enddate 2>/dev/null | cut -d= -f2)"; then
        days=$(( ( $(date -d "${not_after}" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
        if   [[ ${days} -lt 0 ]];  then fail "certificate EXPIRED ${days#-} days ago"
        elif [[ ${days} -lt 14 ]]; then fail "certificate expires in ${days} days -- renewal has stopped"
        elif [[ ${days} -lt 30 ]]; then warn "certificate expires in ${days} days"
        else                            pass "certificate valid for ${days} more days"
        fi
    else
        fail "cannot parse ${cert}"
    fi
else
    fail "${cert} not found -- run scripts/gen-local-tls.sh"
fi

# --- 7. Storage ------------------------------------------------------------
head_ "Storage"

if pct="$(${COMPOSE} exec -T app sh -c "df -P /var/www/html/data | awk 'NR==2{print \$5}' | tr -d '%'" 2>/dev/null | tr -d '\r')"; then
    if   [[ ${pct:-0} -ge 90 ]]; then fail "data volume ${pct}% full"
    elif [[ ${pct:-0} -ge 80 ]]; then warn "data volume ${pct}% full"
    else                              pass "data volume ${pct}% used"
    fi
fi

if pct="$(${COMPOSE} exec -T db sh -c "df -P /var/lib/mysql | awk 'NR==2{print \$5}' | tr -d '%'" 2>/dev/null | tr -d '\r')"; then
    if   [[ ${pct:-0} -ge 90 ]]; then fail "database volume ${pct}% full -- MariaDB stops accepting writes when it cannot extend"
    elif [[ ${pct:-0} -ge 80 ]]; then warn "database volume ${pct}% full"
    else                              pass "database volume ${pct}% used"
    fi
fi

# --- 8. Backups ------------------------------------------------------------
head_ "Backups"

if [[ -d "${BACKUP_DIR}" ]]; then
    newest="$(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -n1)"
    if [[ -n "${newest}" ]]; then
        y="${newest:0:4}"; m="${newest:4:2}"; d="${newest:6:2}"; hh="${newest:9:2}"; mm="${newest:11:2}"
        age_h=$(( ( $(date -u +%s) - $(date -u -d "${y}-${m}-${d} ${hh}:${mm}:00" +%s 2>/dev/null || echo 0) ) / 3600 ))
        if   [[ ${age_h} -gt 48 ]]; then fail "newest backup is ${age_h}h old -- the backup job is not running"
        elif [[ ${age_h} -gt 26 ]]; then warn "newest backup is ${age_h}h old"
        else                             pass "newest backup ${newest} (${age_h}h old)"
        fi

        # A backup nobody has proved restorable is a hypothesis. Say so.
        if grep -q '"verified": true' "${BACKUP_DIR}/${newest}/manifest.json" 2>/dev/null; then
            pass "newest backup has been verified restorable"
        else
            warn "newest backup has never been verified -- run scripts/verify-backup.sh"
        fi
    else
        fail "no backups in ${BACKUP_DIR}"
    fi
else
    warn "${BACKUP_DIR} does not exist -- no backup has ever run"
fi

# --- Result ----------------------------------------------------------------
if [[ ${QUIET} -eq 0 ]]; then
    printf '\n\033[1mResult\033[0m\n'
    if   [[ ${FAILURES} -eq 0 && ${WARNINGS} -eq 0 ]]; then printf '  \033[0;32mAll checks passed.\033[0m\n\n'
    elif [[ ${FAILURES} -eq 0 ]]; then printf '  \033[0;33m%d warning(s), no failures.\033[0m\n\n' "${WARNINGS}"
    else
        printf '  \033[0;31m%d failure(s), %d warning(s).\033[0m\n' "${FAILURES}" "${WARNINGS}"
        printf '  Start at docs/runbooks/ -- TROUBLESHOOTING.md indexes them by symptom.\n\n'
    fi
fi

[[ ${FAILURES} -eq 0 ]]
