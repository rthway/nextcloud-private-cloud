#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Configuration validation.
#
# Runs WITHOUT starting the stack, so it is safe in CI and on a laptop with
# nothing running. It catches the class of error that otherwise surfaces as a
# container that starts, reports healthy, and serves the wrong thing.
#
# Nothing here asserts `true` to make a suite look green. Each check either
# exercises a real parser or compares two values that must agree.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "${REPO_ROOT}" || exit 1

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 ;;
esac

# Docker needs a HOST path for -v. On Git Bash that is a Windows path, and
# MSYS_NO_PATHCONV (set above so container-side paths survive) stops the shell
# converting it -- so convert it explicitly.
host_path() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) (cd "$1" && pwd -W) ;;
        *)                    (cd "$1" && pwd) ;;
    esac
}

# nginx -t refuses a config whose ssl_certificate is missing, so the syntax
# check needs certificate material. Generated here rather than committed,
# which keeps a private key -- even a worthless one -- out of the repository
# where it would trip secret scanning and teach a bad habit.
readonly FIXTURE_TLS="${REPO_ROOT}/tests/.tmp/tls"
make_tls_fixture() {
    mkdir -p "${FIXTURE_TLS}"
    [[ -f "${FIXTURE_TLS}/fullchain.pem" ]] && return 0
    (
        cd "${FIXTURE_TLS}" || exit 1
        printf '[req]\nprompt = no\ndistinguished_name = dn\n[dn]\nCN = validation.example.com\n' > f.cnf
        openssl ecparam -genkey -name prime256v1 -out privkey.pem 2>/dev/null
        openssl req -x509 -new -nodes -config f.cnf -key privkey.pem \
            -sha256 -days 1 -out fullchain.pem 2>/dev/null
        rm -f f.cnf
    )
}

PASS=0
FAIL=0
pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Compose interpolation needs a value for every ${VAR:?}. In CI there is no
# .env, so a throwaway one is synthesised. It never starts anything.
if [[ ! -f .env ]]; then
    printf 'no .env found; synthesising a throwaway one for validation only\n'
    cp .env.example .env.validate-tmp
    # One -e per expression, deliberately.
    #
    # An earlier version used a single quoted script with backslash
    # line-continuations. Inside single quotes a backslash-newline is NOT a
    # shell continuation -- it is a literal backslash, newline and leading
    # whitespace inside the sed script, so only the first expression
    # reliably applied. Every other secret stayed empty, and the failure
    # surfaced only in CI (where this path runs) and never locally (where a
    # real .env exists and this branch is skipped).
    sed -i \
        -e 's|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=validation-only-not-a-real-secret|' \
        -e 's|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=validation-only-not-a-real-secret|' \
        -e 's|^REDIS_PASSWORD=.*|REDIS_PASSWORD=validation-only-not-a-real-secret|' \
        -e 's|^NEXTCLOUD_ADMIN_PASSWORD=.*|NEXTCLOUD_ADMIN_PASSWORD=validation-only-not-a-real-secret|' \
        -e 's|^NEXTCLOUD_METRICS_TOKEN=.*|NEXTCLOUD_METRICS_TOKEN=validation-only-not-a-real-secret|' \
        -e 's|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=validation-only-not-a-real-secret|' \
        .env.validate-tmp
    mv .env.validate-tmp .env
    trap 'rm -f "${REPO_ROOT}/.env"' EXIT
fi

# --- .env parsing ----------------------------------------------------------
head_ "Environment file"

# Every script here does `source .env`, and an unquoted value containing a
# space is parsed as a command. Compose tolerates it; bash does not -- which
# produced "localhost: command not found" from a perfectly valid Compose file.
if ( set -a; source .env.example; set +a ) 2>/dev/null; then
    pass ".env.example is parseable by the shell"
else
    fail ".env.example breaks 'source' -- a value with spaces needs quoting"
    ( set -a; source .env.example; set +a ) 2>&1 | head -3 | sed 's/^/        /'
fi

# --- Compose ---------------------------------------------------------------
head_ "Compose"

docker compose config --quiet 2>/dev/null \
    && pass "compose.yml renders" \
    || { fail "compose.yml is invalid"; docker compose config 2>&1 | tail -5 | sed 's/^/        /'; }

if docker compose -f compose.yml -f compose.observability.yml config --quiet 2>/dev/null; then
    pass "compose.yml + compose.observability.yml render"
else
    # Printing the reason is not optional. An earlier version reported only
    # "the observability overlay is invalid", which said nothing useful when
    # it failed in CI and passed locally.
    fail "the observability overlay is invalid"
    docker compose -f compose.yml -f compose.observability.yml config 2>&1 | tail -6 | sed 's/^/        /'
fi

mkdir -p secrets
for f in mysql_password mysql_root_password redis_password nextcloud_admin_password; do
    [[ -f "secrets/${f}" ]] || echo "validation-placeholder" > "secrets/${f}"
done

if NEXTCLOUD_IMAGE=ghcr.io/example/nc NEXTCLOUD_IMAGE_TAG=validation \
   docker compose -f compose.yml -f compose.prod.yml config --quiet 2>/dev/null; then
    pass "compose.yml + compose.prod.yml render"
else
    fail "the production overlay is invalid"
    NEXTCLOUD_IMAGE=ghcr.io/example/nc NEXTCLOUD_IMAGE_TAG=validation \
        docker compose -f compose.yml -f compose.prod.yml config 2>&1 | tail -5 | sed 's/^/        /'
fi

compose_json() { docker compose config 2>/dev/null; }

# The database and Redis must never be reachable from the host. This is the
# most common self-inflicted exposure in a Compose deployment, so it is
# asserted rather than trusted.
for svc in db redis app cron; do
    if compose_json | python -c "
import sys, yaml
cfg = yaml.safe_load(sys.stdin)
sys.exit(1 if cfg['services'].get('${svc}', {}).get('ports') else 0)
"; then
        pass "the ${svc} service publishes no host port"
    else
        fail "the ${svc} service publishes a host port"
    fi
done

# The backend network must stay internal, or the segmentation is decorative.
if compose_json | python -c "
import sys, yaml
cfg = yaml.safe_load(sys.stdin)
sys.exit(0 if cfg.get('networks', {}).get('backend', {}).get('internal') else 1)
"; then
    pass "the backend network is internal"
else
    fail "the backend network is not marked internal"
fi

# The proxy must carry the domain alias. Without it, anything inside the stack
# reaching the proxy by service name sends Host: proxy, which Nextcloud
# rejects with 400 -- and the tempting fix (adding it to trusted_domains)
# weakens a real control against host-header poisoning.
if compose_json | python -c "
import sys, yaml
cfg = yaml.safe_load(sys.stdin)
nets = cfg['services']['proxy'].get('networks') or {}
aliases = (nets.get('frontend') or {}).get('aliases') or []
sys.exit(0 if any('nextcloud' in a for a in aliases) else 1)
"; then
    pass "the proxy carries a domain alias on the frontend network"
else
    fail "the proxy has no domain alias -- internal clients will get HTTP 400"
fi

# MariaDB isolation and binlog format are set on the command line because they
# must apply before the config file is read. Both are load-bearing: Nextcloud
# deadlocks under REPEATABLE-READ, and STATEMENT binlog reproduces its
# non-deterministic statements incorrectly.
db_cmd="$(compose_json | python -c "
import sys, yaml
cfg = yaml.safe_load(sys.stdin)
print(' '.join(cfg['services']['db'].get('command') or []))
" 2>/dev/null)"
grep -q 'transaction-isolation=READ-COMMITTED' <<<"${db_cmd}" \
    && pass "MariaDB starts with READ-COMMITTED isolation" \
    || fail "MariaDB is missing --transaction-isolation=READ-COMMITTED"
grep -q 'binlog-format=ROW' <<<"${db_cmd}" \
    && pass "MariaDB starts with ROW binlog format" \
    || fail "MariaDB is missing --binlog-format=ROW"

# --- Credentials -----------------------------------------------------------
head_ "Credentials"

git ls-files 2>/dev/null | grep -qE '(^|/)\.env$' \
    && fail ".env is tracked by git" || pass ".env is not tracked by git"

git check-ignore -q .env 2>/dev/null \
    && pass ".env is covered by .gitignore" || fail ".env is not git-ignored"

git ls-files 2>/dev/null | grep -qE 'monitoring/mysqld-exporter/my\.cnf$' \
    && fail "the rendered exporter credentials file is tracked" \
    || pass "the rendered exporter credentials file is not tracked"

if docker compose config 2>/dev/null | grep -iE '(password|passwd|secret):\s*["'\'']?(admin|nextcloud|changeme|password|secret|test)["'\'']?\s*$'; then
    fail "a well-known literal credential appears in the rendered compose config"
else
    pass "no well-known literal credentials in the rendered compose config"
fi

# --- YAML ------------------------------------------------------------------
head_ "YAML"

# Compose defines its own tags (!reset, !override) for merge control across
# overlays. They are valid Compose and unknown to a stock PyYAML loader, so
# the loader is taught about them rather than the overlay being contorted.
yaml_check() {
    python - "$1" <<'PYYAML' 2>&1
import sys
import yaml


class ComposeLoader(yaml.SafeLoader):
    """SafeLoader that tolerates Docker Compose's merge-control tags."""


def _passthrough(loader, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_mapping(node)


for tag in ("!reset", "!override"):
    ComposeLoader.add_constructor(tag, _passthrough)

with open(sys.argv[1], encoding="utf-8") as fh:
    yaml.load(fh, Loader=ComposeLoader)
PYYAML
}

for f in $(git ls-files '*.yml' '*.yaml' 2>/dev/null); do
    if err="$(yaml_check "${f}")" && [[ -z "${err}" ]]; then
        pass "parses: ${f}"
    else
        fail "does not parse: ${f}"
        sed 's/^/        /' <<<"${err}" | tail -3
    fi
done

for f in $(git ls-files '*.json' 2>/dev/null); do
    python -c "import json;json.load(open('${f}',encoding='utf-8'))" 2>/dev/null \
        && pass "parses: ${f}" || fail "does not parse: ${f}"
done

# --- Prometheus ------------------------------------------------------------
head_ "Prometheus"

promtool() {
    docker run --rm -v "$(host_path monitoring):/m:ro" \
        --entrypoint promtool prom/prometheus:v3.14.0 "$@" 2>&1
}

out=$(promtool check config /m/prometheus/prometheus.yml)
grep -q SUCCESS <<<"${out}" && pass "prometheus.yml is valid" \
    || { fail "prometheus.yml is invalid"; sed 's/^/        /' <<<"${out}" | tail -5; }

out=$(promtool check rules /m/alerts/nextcloud.yml)
grep -q SUCCESS <<<"${out}" && pass "alert rules are valid ($(grep -oE '[0-9]+ rules found' <<<"${out}"))" \
    || { fail "alert rules are invalid"; sed 's/^/        /' <<<"${out}" | tail -5; }

# An alert that fires at 3am and offers no next step produces stress and no
# repair, so the convention is enforced rather than documented.
missing_runbooks=$(python - <<'PY' | tr -d '\r'
import yaml
doc = yaml.safe_load(open('monitoring/alerts/nextcloud.yml', encoding='utf-8'))
print(' '.join(
    rule['alert']
    for group in doc['groups']
    for rule in group.get('rules', [])
    if 'alert' in rule and not rule.get('annotations', {}).get('runbook')
))
PY
)
[[ -z "${missing_runbooks}" ]] && pass "every alert names a runbook" \
    || fail "alerts without a runbook annotation: ${missing_runbooks}"

# A runbook link that 404s is worse than none, because it is trusted at 3am.
runbook_refs="$(python - <<'PY' | tr -d '\r'
import yaml
doc = yaml.safe_load(open('monitoring/alerts/nextcloud.yml', encoding='utf-8'))
seen = set()
for group in doc['groups']:
    for rule in group.get('rules', []):
        rb = rule.get('annotations', {}).get('runbook')
        if rb and rb not in seen:
            seen.add(rb)
            print(rb)
PY
)"
broken_runbooks=""
for rb in ${runbook_refs}; do
    [[ -f "${rb}" ]] || broken_runbooks="${broken_runbooks} ${rb}"
done
[[ -z "${broken_runbooks}" ]] && pass "every referenced runbook file exists" \
    || fail "alerts reference missing runbooks:${broken_runbooks}"

# --- nginx -----------------------------------------------------------------
head_ "nginx"

make_tls_fixture

# --add-host: nginx resolves every `upstream` server name at config load and
# refuses to start with "host not found in upstream" if it cannot. The stack
# is not running during a config check -- that is the point of a config check.
nginx_test=$(docker run --rm \
    --add-host app:127.0.0.1 \
    -e NEXTCLOUD_DOMAIN=validation.example.com \
    -e PHP_UPLOAD_LIMIT=10G \
    -e NGINX_ENVSUBST_FILTER='^(NEXTCLOUD_|PHP_)' \
    -v "$(host_path config/nginx)/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$(host_path config/nginx/conf.d):/etc/nginx/templates:ro" \
    -v "$(host_path config/nginx/snippets):/etc/nginx/snippets:ro" \
    -v "$(host_path tests/.tmp/tls):/etc/nginx/tls:ro" \
    --entrypoint /bin/sh \
    nginx:1.31.4-alpine3.24 -c \
    '/docker-entrypoint.d/20-envsubst-on-templates.sh >/dev/null 2>&1; nginx -t' 2>&1)

if grep -q "syntax is ok" <<<"${nginx_test}" && grep -q "test is successful" <<<"${nginx_test}"; then
    pass "nginx configuration is valid"
else
    fail "nginx configuration is invalid"
    sed 's/^/        /' <<<"${nginx_test}" | tail -6
fi

# The paths that must never be served. A vhost missing this block leaks
# config.php, which contains the database password -- a known way to lose a
# Nextcloud instance entirely.
vhost=config/nginx/conf.d/nextcloud.conf.template
for pattern in 'config' 'data' 'lib' '3rdparty'; do
    grep -qE "location ~ \^/\(\?:.*${pattern}" "${vhost}" \
        && pass "vhost blocks /${pattern}" \
        || fail "vhost does NOT block /${pattern} -- this leaks user data or credentials"
done

# An open `location ~ \.php$` would let any uploaded .php file in the data
# directory execute, which on a file-sharing server is RCE by design.
grep -q 'rewrite \^/(?!index|remote|public|cron' "${vhost}" \
    && pass "PHP execution is restricted to Nextcloud's entry points" \
    || fail "the PHP location does not restrict entry points"

grep -q 'try_files \$fastcgi_script_name =404' "${vhost}" \
    && pass "fastcgi try_files =404 guard present" \
    || fail "missing try_files =404 -- path traversal could reach arbitrary files"

# CalDAV/CardDAV discovery. Without these, calendar and contact sync fails to
# auto-configure and Nextcloud's admin overview reports a setup warning.
grep -q 'location = /.well-known/carddav' "${vhost}" \
    && pass "CardDAV discovery redirect present" || fail "CardDAV discovery redirect missing"
grep -q 'location = /.well-known/caldav' "${vhost}" \
    && pass "CalDAV discovery redirect present" || fail "CalDAV discovery redirect missing"

# --- Managed Nextcloud config ---------------------------------------------
head_ "Nextcloud configuration template"

render=$(python - <<'PY' | tr -d '\r'
import re
import sys

env = {
    "DEFAULT_QUOTA": "10 GB",
}
text = open("config/nextcloud/zz-managed.config.php.tmpl", encoding="utf-8").read()

unresolved = [k for k in set(re.findall(r"\$\{([A-Z0-9_]+)\}", text)) if k not in env]
if unresolved:
    sys.exit("unresolved placeholders: " + ", ".join(sorted(unresolved)))

for key, value in env.items():
    text = text.replace("${" + key + "}", value)

# Settings that must not regress.
if "'backgroundjobs_mode' => 'cron'" not in text:
    sys.exit("backgroundjobs_mode must be 'cron' -- 'ajax' means jobs only run on page loads")
if "'log_type' => 'errorlog'" not in text:
    sys.exit("log_type must be 'errorlog' so logs go to the container runtime")
if "'auth.bruteforce.protection.enabled' => true" not in text:
    sys.exit("brute-force protection must stay enabled")
# Look for an assignment, not the word. The template deliberately DISCUSSES
# memcache.locking in a comment explaining why it is absent, and an earlier
# version of this check matched that comment and failed on a correct file.
if re.search(r"^\s*'memcache\.locking'\s*=>", text, re.M):
    sys.exit("memcache.locking must NOT be set here -- the upstream image sets it, and "
             "redefining the nested 'redis' array would delete its host and password")
print("ok")
PY
)
[[ "${render}" == "ok" ]] && pass "zz-managed.config.php.tmpl renders and its invariants hold" \
    || fail "zz-managed.config.php.tmpl: ${render}"

# --- Cross-file consistency ------------------------------------------------
head_ "Consistency"

# The connection budget must fit. PHP-FPM opens roughly one database
# connection per worker; exceeding max_connections means workers that cannot
# connect and requests that fail outright.
budget=$(python - <<'PY' | tr -d '\r'
import re


def env_val(key, default):
    for line in open(".env.example", encoding="utf-8"):
        if line.startswith(key + "="):
            raw = line.split("=", 1)[1].split("#")[0].strip().strip('"')
            try:
                return int(raw)
            except ValueError:
                return default
    return default


children = env_val("PHP_FPM_MAX_CHILDREN", 32)
conf = open("config/mariadb/my.cnf", encoding="utf-8").read()
limit = int(re.search(r"^max_connections\s*=\s*(\d+)", conf, re.M).group(1))
# app workers + cron + exporter + operator headroom
print(f"{children + 4 + 3 + 5} {limit}")
PY
)
read -r used limit <<<"${budget}"
[[ "${used}" -lt "${limit}" ]] \
    && pass "connection budget fits: ~${used} needed, max_connections is ${limit}" \
    || fail "connection budget does NOT fit: ~${used} needed, max_connections is only ${limit}"

# The image versions quoted in NOTICE.md must match what is deployed, or the
# licence inventory describes something else.
for pin in NEXTCLOUD_VERSION MARIADB_VERSION REDIS_VERSION NGINX_VERSION; do
    v=$(grep -E "^${pin}=" .env.example | cut -d= -f2 | tr -d ' ')
    grep -q "\`${v}\`" NOTICE.md \
        && pass "NOTICE.md records ${pin}=${v}" \
        || fail "NOTICE.md does not record ${pin}=${v} -- the licence inventory is stale"
done

printf '\n\033[1mConfiguration: %d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
