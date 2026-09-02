#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Security scanning: secrets, filesystem, container images.
#
# Two rules govern what fails the build:
#
#   1. A leaked secret always fails. There is no acceptable level.
#   2. Vulnerabilities fail on HIGH and CRITICAL only, and only where they are
#      actually fixable. An unfixable CVE in an upstream base image is
#      documented in SECURITY.md, not suppressed to make a badge green --
#      suppressing it means the next one is invisible too.
#
#   ./tests/test-security.sh              # secrets + filesystem
#   ./tests/test-security.sh --image      # also scan the built image (slower)
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "${REPO_ROOT}" || exit 1

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 ;;
esac

host_path() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) (cd "$1" && pwd -W) ;;
        *)                    (cd "$1" && pwd) ;;
    esac
}
HOST_ROOT="$(host_path .)"
readonly HOST_ROOT

SCAN_IMAGE=0
[[ "${1:-}" == "--image" ]] && SCAN_IMAGE=1

PASS=0
FAIL=0
pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
warn() { printf '  \033[0;33mWARN\033[0m  %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

readonly TRIVY_IMAGE=aquasec/trivy:0.74.0
readonly GITLEAKS_IMAGE=zricethezav/gitleaks:v8.21.2

printf 'preparing scanner images'
for img in "${TRIVY_IMAGE}" "${GITLEAKS_IMAGE}"; do
    docker image inspect "${img}" >/dev/null 2>&1 || docker pull -q "${img}" >/dev/null 2>&1
    printf '.'
done
printf ' done\n'

# --- Secrets ---------------------------------------------------------------
head_ "Secret scanning (gitleaks)"

# Scans the working tree AND the git history. History matters: a secret
# committed and then removed in a later commit is still in the repository and
# still compromised, and `git log -p` will find it long after the file is gone.
leaks_out=$(docker run --rm -v "${HOST_ROOT}:/repo:ro" -w /repo \
    "${GITLEAKS_IMAGE}" detect --source=/repo --no-banner --redact --exit-code 1 2>&1)
leaks_rc=$?

if [[ ${leaks_rc} -eq 0 ]]; then
    pass "no secrets found in the working tree or git history"
else
    fail "gitleaks found potential secrets"
    sed 's/^/        /' <<<"${leaks_out}" | tail -25
fi

# --- Files that must never be tracked --------------------------------------
head_ "Sensitive files"

# Belt and braces alongside gitleaks: an empty or unusually-formatted key file
# can slip past a content scanner but is unambiguous by name.
tracked_bad=$(git ls-files 2>/dev/null | grep -E '(^|/)(\.env|secrets/|.*\.key|.*\.pem|id_rsa|.*\.p12|.*\.pfx)$' \
    | grep -v '\.example$' || true)
if [[ -z "${tracked_bad}" ]]; then
    pass "no credential-shaped files are tracked"
else
    fail "credential-shaped files are tracked by git:"
    sed 's/^/        /' <<<"${tracked_bad}"
fi

for path in .env secrets backups config/nginx/tls/privkey.pem tests/.tmp monitoring/mysqld-exporter/my.cnf; do
    if git check-ignore -q "${path}" 2>/dev/null; then
        pass "git-ignored: ${path}"
    else
        fail "NOT git-ignored: ${path}"
    fi
done

# --- Filesystem vulnerabilities --------------------------------------------
head_ "Filesystem scan (Trivy)"

# Also covers misconfiguration: Trivy's config scanner reads Dockerfiles and
# Compose files and flags things like a missing USER directive or a privileged
# container.
# Trivy scans the working tree, not the git index, so it has no notion of
# .gitignore. The skipped directories hold runtime-generated material that is
# git-ignored by design -- the local development TLS keys, Docker secret
# files, backups -- and Trivy correctly identifies the private keys in them as
# private keys.
#
# Skipping them does NOT weaken the check that matters. The "Sensitive files"
# section above asserts against `git ls-files`, so a key that is actually
# committed still fails, and gitleaks independently scans the full history.
fs_out=$(docker run --rm \
    -v "${HOST_ROOT}:/scan:ro" \
    -v nextcloud-trivy-cache:/root/.cache/trivy \
    "${TRIVY_IMAGE}" fs /scan \
    --scanners vuln,secret,misconfig \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --exit-code 1 \
    --no-progress \
    --skip-dirs /scan/backups \
    --skip-dirs /scan/tests/.tmp \
    --skip-dirs /scan/secrets \
    --skip-dirs /scan/config/nginx/tls \
    --skip-dirs /scan/monitoring/mysqld-exporter \
    --ignorefile /scan/.trivyignore 2>&1)
fs_rc=$?

if [[ ${fs_rc} -eq 0 ]]; then
    pass "no fixable HIGH/CRITICAL findings in the filesystem"
else
    fail "Trivy filesystem scan found issues"
    sed 's/^/        /' <<<"${fs_out}" | tail -40
fi

# --- Image vulnerabilities -------------------------------------------------
head_ "Image scan (Trivy)"

image="${NEXTCLOUD_IMAGE:-nextcloud-private-cloud}:${NEXTCLOUD_IMAGE_TAG:-local}"

if [[ ${SCAN_IMAGE} -eq 0 ]]; then
    warn "skipped (pass --image to scan ${image})"
elif ! docker image inspect "${image}" >/dev/null 2>&1; then
    warn "image ${image} not built; run: make build"
else
    # --ignore-unfixed is the important flag. The Odoo base image is a large
    # Debian userland and always carries some open CVEs with no released fix.
    # Failing on those means the pipeline is red permanently, which trains
    # everyone to ignore it -- and then a genuinely fixable CRITICAL goes
    # unnoticed. Unfixed findings are reviewed and recorded in SECURITY.md
    # instead.
    img_out=$(docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v nextcloud-trivy-cache:/root/.cache/trivy \
        "${TRIVY_IMAGE}" image "${image}" \
        --severity HIGH,CRITICAL \
        --ignore-unfixed \
        --exit-code 1 \
        --no-progress 2>&1)
    img_rc=$?

    if [[ ${img_rc} -eq 0 ]]; then
        pass "no fixable HIGH/CRITICAL vulnerabilities in ${image}"
    else
        fail "fixable HIGH/CRITICAL vulnerabilities in ${image}"
        sed 's/^/        /' <<<"${img_out}" | tail -40
    fi

    # Reported, never failed on: an informational count of what cannot be
    # fixed today, so the number is visible rather than silently discarded.
    unfixed=$(docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v nextcloud-trivy-cache:/root/.cache/trivy \
        "${TRIVY_IMAGE}" image "${image}" \
        --severity HIGH,CRITICAL --format json --no-progress 2>/dev/null \
        | python -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print('unknown'); raise SystemExit(0)
n = sum(
    1
    for result in (data.get('Results') or [])
    for v in (result.get('Vulnerabilities') or [])
    if not v.get('FixedVersion')
)
print(n)
" 2>/dev/null | tr -d '\r')
    warn "${unfixed} HIGH/CRITICAL finding(s) with no upstream fix available -- see SECURITY.md"
fi

# --- Configuration posture -------------------------------------------------
head_ "Posture"

# A single well-known credential in a committed file undoes everything else.
if grep -rIE --exclude-dir=.git --exclude-dir=backups --exclude-dir=.tmp \
     "(PASSWORD|PASSWD|SECRET|TOKEN)\s*[:=]\s*[\"']?(admin|odoo|password|changeme|secret|test|123)[\"']?\s*$" \
     . 2>/dev/null | grep -v '\.example:' | grep -v 'test-security.sh'; then
    fail "a well-known credential literal is present in a tracked file"
else
    pass "no well-known credential literals"
fi

# Unlike the Odoo image, this one deliberately ends as root: PHP-FPM's master
# process needs it to create the pool listener and to populate the html volume
# on first start, and it drops to www-data for every worker. Asserting
# "ends as non-root" here would be wrong.
#
# What IS asserted is that the workers run unprivileged -- verified against the
# running container by the smoke suite -- and that the production overlay drops
# capabilities.
if grep -qE '^USER root' docker/nextcloud/Dockerfile; then
    pass "Dockerfile runs as root by design (PHP-FPM master binds the pool listener)"
else
    warn "Dockerfile does not declare USER root; verify the FPM master can still start"
fi

if grep -q 'cap_drop' compose.prod.yml 2>/dev/null; then
    pass "the production overlay drops capabilities"
else
    fail "compose.prod.yml does not drop capabilities"
fi

# No image may be pulled by a floating tag.
if grep -rnE 'image:\s*[a-z0-9./_-]+:latest' compose*.yml 2>/dev/null; then
    fail "an image is pinned to :latest"
else
    pass "no image uses the :latest tag"
fi

# --- Result ----------------------------------------------------------------
printf '\n\033[1mSecurity: %d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
