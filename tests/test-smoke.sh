#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Smoke tests against a running stack.
#
# These exercise the real request path -- browser to nginx to PHP-FPM to
# MariaDB -- rather than asserting containers exist. Every check has a
# plausible way to fail in production.
#
# Requires the stack to be up:  make up
#
# Probes run from inside the container network, so the suite needs no curl on
# the host, no TLS trust configuration and no hosts entry, and behaves
# identically on a laptop and on a CI runner.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "${REPO_ROOT}" || exit 1

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 ;;
esac

PASS=0
FAIL=0
pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[[ -f .env ]] || { printf 'ERROR: .env not found. Run make setup first.\n' >&2; exit 1; }
# shellcheck disable=SC1091
set -a; source .env; set +a
: "${NEXTCLOUD_DOMAIN:=nextcloud.localhost}"
: "${MYSQL_DATABASE:=nextcloud}"

docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx proxy \
    || { printf 'ERROR: the stack is not running. Run: make up\n' >&2; exit 1; }

db_root() { docker compose exec -e "MYSQL_PWD=${MYSQL_ROOT_PASSWORD}" -T db mariadb -u root "$@"; }
occ()     { docker compose exec --user www-data -T app php occ "$@"; }

# HTTP probe from inside the app container. Certificate verification is off:
# this suite tests routing and behaviour, and the certificate is validated
# separately against the file on disk. Conflating the two makes a local
# self-signed certificate look like an application outage.
#
# The proxy is reached by the real hostname via its network alias, so the Host
# header matches both nginx's server_name and Nextcloud's trusted_domains --
# exactly as a browser's would.
probe() {
    docker compose exec -T app php -r '
        $ctx = stream_context_create([
            "ssl"  => ["verify_peer" => false, "verify_peer_name" => false],
            "http" => ["timeout" => 15, "ignore_errors" => true,
                       "follow_location" => 0, "method" => "GET"],
        ]);
        @file_get_contents("https://'"${NEXTCLOUD_DOMAIN}"'" . $argv[1], false, $ctx);
        if (!isset($http_response_header[0])) { echo "000"; exit; }
        preg_match("#HTTP/\S+ (\d{3})#", $http_response_header[0], $m);
        echo $m[1] ?? "000";
    ' -- "$1" 2>/dev/null | tr -d '\r'
}

probe_headers() {
    docker compose exec -T app php -r '
        $ctx = stream_context_create([
            "ssl"  => ["verify_peer" => false, "verify_peer_name" => false],
            "http" => ["timeout" => 15, "ignore_errors" => true, "follow_location" => 0],
        ]);
        @file_get_contents("https://'"${NEXTCLOUD_DOMAIN}"'" . $argv[1], false, $ctx);
        foreach ($http_response_header ?? [] as $h) { echo strtolower($h), "\n"; }
    ' -- "$1" 2>/dev/null | tr -d '\r'
}

# --- Application ------------------------------------------------------------
head_ "Application"

code="$(probe /status.php)"
[[ "${code}" == "200" ]] && pass "/status.php -> 200" || fail "/status.php -> ${code}"

body="$(docker compose exec -T app php -r '
    $ctx = stream_context_create(["ssl"=>["verify_peer"=>false,"verify_peer_name"=>false],
                                  "http"=>["timeout"=>15,"ignore_errors"=>true]]);
    echo @file_get_contents("https://'"${NEXTCLOUD_DOMAIN}"'/status.php", false, $ctx);
' 2>/dev/null | tr -d '\r')"

[[ "${body}" == *'"installed":true'* ]] && pass "reports installed: true" \
    || fail "status.php did not report installed: ${body}"
[[ "${body}" == *'"maintenance":false'* ]] && pass "not in maintenance mode" \
    || fail "instance is in maintenance mode"
[[ "${body}" == *'"needsDbUpgrade":false'* ]] && pass "no pending database upgrade" \
    || fail "a database upgrade is pending"

# The login page is a stronger signal than status.php: it exercises the full
# app stack. A failed app upgrade shows up here first.
code="$(probe /login)"
[[ "${code}" == "200" ]] && pass "/login -> 200" || fail "/login -> ${code}"

# WebDAV is what desktop and mobile sync clients actually use -- a different
# code path from the web UI, and the one most users depend on. 401 is correct
# for an unauthenticated request.
code="$(probe /remote.php/dav/)"
[[ "${code}" =~ ^(401|207)$ ]] && pass "/remote.php/dav/ -> ${code} (WebDAV reachable)" \
    || fail "/remote.php/dav/ -> ${code}, expected 401"

# Service discovery. Without these, calendar and contact sync cannot
# auto-configure and Nextcloud's admin overview reports a setup warning.
for p in /.well-known/caldav /.well-known/carddav; do
    code="$(probe "${p}")"
    [[ "${code}" == "301" ]] && pass "${p} -> 301" || fail "${p} -> ${code}, expected 301"
done

# --- Security ---------------------------------------------------------------
head_ "Security"

# These must never be served. config.php contains the database password;
# data/ contains every user's files. A vhost missing these rules is a known
# way to lose a Nextcloud instance entirely.
for p in /config/config.php /data/.ocdata /lib/base.php /3rdparty/autoload.php /db_structure.xml; do
    code="$(probe "${p}")"
    [[ "${code}" == "404" ]] && pass "${p} blocked (404)" || fail "${p} -> ${code}; must be 404"
done

headers="$(probe_headers /login)"

check_header() {
    local name="$1" expected="$2" value
    value="$(grep -i "^${name}:" <<<"${headers}" | head -1 | cut -d' ' -f2-)"
    # probe_headers lowercases every header line, so the comparison is
    # case-insensitive. Comparing against 'SAMEORIGIN' literally fails on a
    # perfectly correct header.
    local value_lc="${value,,}" expected_lc="${expected,,}"
    if [[ -z "${value}" ]]; then
        fail "missing header: ${name}"
    elif [[ -n "${expected}" && "${value_lc}" != *"${expected_lc}"* ]]; then
        fail "${name}: '${value}' does not contain '${expected}'"
    else
        pass "${name}: ${value}"
    fi
}

check_header "strict-transport-security" "max-age="
check_header "x-frame-options"           "SAMEORIGIN"
check_header "x-content-type-options"    "nosniff"
check_header "referrer-policy"           "no-referrer"
check_header "x-robots-tag"              "noindex"
check_header "x-permitted-cross-domain-policies" "none"

# Duplicated security headers are not merely untidy: where two values
# disagree, browsers do not resolve them consistently and the weaker one can
# win. Nextcloud sets several itself, so fastcgi_hide_header is what keeps
# these unique.
for h in x-frame-options x-content-type-options strict-transport-security referrer-policy x-robots-tag; do
    count="$(grep -ci "^${h}:" <<<"${headers}")"
    [[ "${count}" -le 1 ]] && pass "${h} appears once" \
        || fail "${h} appears ${count} times -- the upstream copy is not hidden"
done

grep -qi '^server: nginx$' <<<"${headers}" && pass "server header does not leak a version" \
    || fail "server header: $(grep -i '^server:' <<<"${headers}")"

# --- Redirect ---------------------------------------------------------------
head_ "Redirect"

redirect="$(docker compose exec -T app php -r '
    $ctx = stream_context_create(["http"=>["timeout"=>10,"ignore_errors"=>true,"follow_location"=>0]]);
    @file_get_contents("http://'"${NEXTCLOUD_DOMAIN}"'/", false, $ctx);
    $status = "000"; $loc = "";
    foreach ($http_response_header ?? [] as $h) {
        if (preg_match("#HTTP/\S+ (\d{3})#", $h, $m)) $status = $m[1];
        if (stripos($h, "location:") === 0) $loc = trim(substr($h, 9));
    }
    echo $status, " ", $loc;
' 2>/dev/null | tr -d '\r')"

read -r status location <<<"${redirect}"
[[ "${status}" == "301" ]] && pass "plain HTTP -> 301" || fail "plain HTTP -> ${status}"
[[ "${location}" == https://* ]] && pass "redirect target is https: ${location}" \
    || fail "redirect target is not https: ${location}"

# --- Network isolation ------------------------------------------------------
head_ "Network isolation"

# Read the container's actual port bindings. `docker compose port` exits 0 and
# prints "invalid IP:0" when a port is unpublished, so both its exit status
# and a naive emptiness test report every stack as exposed.
assert_not_published() {
    local svc="$1" cid bindings
    cid="$(docker compose ps -q "${svc}" 2>/dev/null)"
    [[ -n "${cid}" ]] || { fail "${svc}: container not found"; return; }
    bindings="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "${cid}" 2>/dev/null | tr -d '\r')"
    if [[ "${bindings}" == "{}" || "${bindings}" == "null" || -z "${bindings}" ]]; then
        pass "${svc} publishes no host port"
    else
        fail "${svc} publishes host ports: ${bindings}"
    fi
}

assert_not_published db
assert_not_published redis
assert_not_published app
assert_not_published cron

# The backend network is internal, so a compromised database or Redis cannot
# call home. Verified rather than assumed.
if docker compose exec -T db sh -c 'timeout 5 curl -sS -o /dev/null http://example.com' 2>/dev/null; then
    fail "the db container reached the internet -- the backend network is not isolated"
else
    pass "the db container cannot reach the internet"
fi

# --- Caching and locking ----------------------------------------------------
head_ "Caching and file locking"

# The most important application invariant on this stack. Without Redis
# locking, concurrent access produces "file is locked" errors users report as
# corruption.
locking="$(occ config:system:get memcache.locking 2>/dev/null | tr -d '\r')"
[[ "${locking}" == *"Redis"* ]] && pass "memcache.locking = ${locking}" \
    || fail "memcache.locking is '${locking:-unset}', expected Redis"

localcache="$(occ config:system:get memcache.local 2>/dev/null | tr -d '\r')"
[[ "${localcache}" == *"APCu"* ]] && pass "memcache.local = ${localcache}" \
    || fail "memcache.local is '${localcache:-unset}', expected APCu"

bgmode="$(occ config:system:get backgroundjobs_mode 2>/dev/null | tr -d '\r')"
[[ "${bgmode}" == "cron" ]] && pass "backgroundjobs_mode = cron" \
    || fail "backgroundjobs_mode is '${bgmode:-unset}' -- with 'ajax', scheduled work barely runs"

if docker compose exec -T redis redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
    pass "Redis responds to an authenticated ping"
else
    fail "Redis did not respond"
fi

# An unauthenticated ping must be refused -- otherwise anything on the network
# can flush the lock store.
if docker compose exec -T redis redis-cli ping 2>&1 | grep -qi 'NOAUTH\|denied'; then
    pass "Redis refuses unauthenticated commands"
else
    fail "Redis answered without authentication"
fi

# volatile-lru, not allkeys-lru: file locks have no TTL, and allkeys-* would
# permit evicting them, which is silent corruption rather than a cache miss.
# Read from INFO rather than CONFIG GET. redis.conf renames CONFIG away as
# deliberate hardening -- an application bug or an injection reaching Redis
# should not be able to reconfigure it -- so `CONFIG GET` returns
# "ERR unknown command 'config'". That is the hardening working correctly,
# and the test has to use a channel that still exists.
policy="$(docker compose exec -T redis redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning info memory 2>/dev/null | grep -i '^maxmemory_policy:' | cut -d: -f2 | tr -d '\r')"
[[ "${policy}" == "volatile-lru" ]] && pass "maxmemory-policy = volatile-lru (locks cannot be evicted)" \
    || fail "maxmemory-policy is '${policy}', expected volatile-lru"

# --- Database ---------------------------------------------------------------
head_ "MariaDB"

db_root -e "SELECT 1;" >/dev/null 2>&1 && pass "accepting connections" || fail "not accepting connections"

q() { db_root -N -B -e "$1" 2>/dev/null | tr -d '\r'; }

iso="$(q "SELECT @@transaction_isolation;")"
[[ "${iso}" == "READ-COMMITTED" ]] && pass "transaction isolation: READ-COMMITTED" \
    || fail "isolation is '${iso}' -- Nextcloud deadlocks under REPEATABLE-READ"

binlog="$(q "SELECT @@binlog_format;")"
[[ "${binlog}" == "ROW" ]] && pass "binlog format: ROW" \
    || fail "binlog format is '${binlog}' -- STATEMENT is unsafe with Nextcloud's queries"

charset="$(q "SELECT default_character_set_name FROM information_schema.schemata WHERE schema_name='${MYSQL_DATABASE}';")"
[[ "${charset}" == "utf8mb4" ]] && pass "character set: utf8mb4" \
    || fail "character set is '${charset}' -- utf8mb3 cannot store emoji or CJK filenames"

tables="$(q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}';")"
[[ "${tables:-0}" -gt 50 ]] && pass "schema present (${tables} tables)" \
    || fail "only ${tables:-0} tables"

# --- Container posture ------------------------------------------------------
head_ "Container posture"

# The Dockerfile deliberately ends as root because PHP-FPM's master needs it.
# What matters is that the WORKERS -- where request handling happens -- do not.
# busybox ps has no -C flag, so `ps -o user,comm` is the portable form. The
# master process is root by design, so root is filtered out and whatever
# remains must be the worker user.
worker_user="$(docker compose exec -T app sh -c 'ps -o user,comm 2>/dev/null | grep php-fpm | grep -v "^root " | awk "{print \$1}" | sort -u | head -1' 2>/dev/null | tr -d '\r ')"
[[ "${worker_user}" == "www-data" ]] && pass "PHP-FPM workers run as www-data (master stays root by design)" \
    || fail "PHP-FPM workers run as '${worker_user}', expected www-data"

for svc in db redis app cron proxy; do
    cid="$(docker compose ps -q "${svc}" 2>/dev/null)"
    [[ -n "${cid}" ]] || { fail "${svc}: not running"; continue; }

    docker inspect --format '{{range .HostConfig.SecurityOpt}}{{.}} {{end}}' "${cid}" 2>/dev/null \
        | grep -q 'no-new-privileges:true' \
        && pass "${svc}: no-new-privileges is set" \
        || fail "${svc}: no-new-privileges is NOT set"
done

# cron has no healthcheck by design -- it runs a sleep loop with no endpoint,
# and a liveness probe would pass while cron.php failed every run.
for svc in db redis app proxy; do
    cid="$(docker compose ps -q "${svc}" 2>/dev/null)"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null)"
    [[ "${health}" == "healthy" ]] && pass "${svc}: healthy" || fail "${svc}: health is '${health}'"
done

# --- TLS --------------------------------------------------------------------
head_ "TLS"

cert="config/nginx/tls/fullchain.pem"
if [[ -f "${cert}" ]]; then
    openssl x509 -in "${cert}" -noout -checkend 0 >/dev/null 2>&1 \
        && pass "certificate is currently valid" || fail "certificate has expired"
    openssl x509 -in "${cert}" -noout -ext subjectAltName 2>/dev/null | grep -q "${NEXTCLOUD_DOMAIN}" \
        && pass "certificate SAN covers ${NEXTCLOUD_DOMAIN}" \
        || fail "certificate SAN does not include ${NEXTCLOUD_DOMAIN}"
else
    fail "no certificate at ${cert}"
fi

printf '\n\033[1mSmoke: %d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
