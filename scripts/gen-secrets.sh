#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Fill the blank secrets in .env with generated values.
#
# Idempotent: a variable that already has a non-empty value is left alone, so
# running this twice cannot rotate a password out from under a running
# database. Rotation is a deliberate procedure -- see OPERATIONS.md.
#
#   ./scripts/gen-secrets.sh          # fill .env, creating it from the example
#   ./scripts/gen-secrets.sh --force  # regenerate even populated values
# ---------------------------------------------------------------------------
set -euo pipefail

# Declared and assigned separately: `readonly x="$(cmd)"` discards the
# command's exit status, so a failing cd would leave REPO_ROOT empty and the
# script would operate relative to the wrong directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly ENV_FILE="${REPO_ROOT}/.env"
readonly ENV_EXAMPLE="${REPO_ROOT}/.env.example"

readonly SECRETS=(
    MYSQL_PASSWORD
    MYSQL_ROOT_PASSWORD
    REDIS_PASSWORD
    NEXTCLOUD_ADMIN_PASSWORD
    GRAFANA_ADMIN_PASSWORD
    NEXTCLOUD_METRICS_TOKEN
)

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

log()  { printf '\033[0;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# openssl rand, not $RANDOM: the latter is a 15-bit PRNG seeded from the pid
# and the clock, which is fine for shuffling a list and useless for a
# credential.
#
# base64 then strip to [A-Za-z0-9]. The stripped characters (+ / =) are
# exactly the ones that break when a password travels through a URL, a shell
# variable, or a database connection string -- and a password that works
# everywhere except in one code path is a bad afternoon.
generate_secret() {
    local length="${1:-40}"
    # Over-generate: the filter removes roughly a quarter of the output, so
    # asking for exactly `length` bytes sometimes returns short.
    openssl rand -base64 $(( length * 3 )) | tr -dc 'A-Za-z0-9' | head -c "${length}"
}

command -v openssl >/dev/null 2>&1 || die "openssl is required and was not found on PATH"

if [[ ! -f "${ENV_FILE}" ]]; then
    [[ -f "${ENV_EXAMPLE}" ]] || die "neither .env nor .env.example exists"
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"
    log "created .env from .env.example"
fi

# 0600 before writing anything: this file is about to hold the database
# password, the Redis password and the Nextcloud admin password.
chmod 600 "${ENV_FILE}"

generated=0
skipped=0

for var in "${SECRETS[@]}"; do
    current="$(sed -n "s/^${var}=//p" "${ENV_FILE}" | head -n1 | sed 's/#.*//' | xargs || true)"

    if [[ -n "${current}" && "${FORCE}" -eq 0 ]]; then
        skipped=$(( skipped + 1 ))
        continue
    fi

    if [[ -n "${current}" && "${FORCE}" -eq 1 ]]; then
        warn "${var} already had a value and --force was given; rotating it"
        case "${var}" in
            MYSQL_PASSWORD|MYSQL_ROOT_PASSWORD)
                warn "  a rotated MariaDB password does NOT change the password inside an"
                warn "  existing database volume. See OPERATIONS.md, 'Rotating credentials'."
                ;;
            NEXTCLOUD_ADMIN_PASSWORD)
                warn "  NEXTCLOUD_ADMIN_PASSWORD is only read during first install. On an"
                warn "  existing instance, change it with: ./scripts/occ.sh user:resetpassword admin"
                ;;
        esac
    fi

    secret="$(generate_secret 40)"

    if grep -qE "^${var}=" "${ENV_FILE}"; then
        tmp="$(mktemp)"
        # awk rather than sed, so characters in the generated secret are never
        # interpreted as regex or as the sed delimiter.
        awk -v key="${var}" -v val="${secret}" \
            'BEGIN{FS=OFS="="} $1==key {print key "=" val; next} {print}' \
            "${ENV_FILE}" > "${tmp}"
        cat "${tmp}" > "${ENV_FILE}"    # preserve the inode and its mode
        rm -f "${tmp}"
    else
        printf '%s=%s\n' "${var}" "${secret}" >> "${ENV_FILE}"
    fi

    log "generated ${var} (40 characters)"
    generated=$(( generated + 1 ))
done

chmod 600 "${ENV_FILE}"
log "done: ${generated} generated, ${skipped} left unchanged"

if [[ "${generated}" -gt 0 ]]; then
    cat <<'NOTE'

  .env now contains live credentials and is mode 0600.

  It is git-ignored. Verify that yourself before your first commit:

      git check-ignore -v .env

  Store NEXTCLOUD_ADMIN_PASSWORD somewhere you will still have access to when
  this host is gone. It is used only during first install and is not
  recoverable from a backup -- afterwards the password lives as an Argon2id
  hash in the database, which is not reversible.

NOTE
fi
