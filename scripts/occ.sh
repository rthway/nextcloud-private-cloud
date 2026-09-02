#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# occ -- Nextcloud's command-line administration tool.
#
# Everything that is not clickable in the web UI happens here: user
# management, app installation, file scans, integrity checks, maintenance
# mode, database repairs.
#
# The wrapper exists because occ MUST run as www-data. Running it as root --
# which `docker compose exec app php occ` does by default -- creates files in
# the data directory owned by root, and Nextcloud then cannot read its own
# files. The symptom is an instance that works until the next upload into an
# affected folder, and the fix is a recursive chown nobody enjoys discovering.
#
#   ./scripts/occ.sh status
#   ./scripts/occ.sh user:list
#   ./scripts/occ.sh maintenance:mode --on
#   ./scripts/occ.sh files:scan --all
#   ./scripts/occ.sh db:add-missing-indices
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "${REPO_ROOT}" || exit 1

# Git Bash and MSYS rewrite absolute POSIX arguments into Windows paths before
# handing them to a native binary. Every absolute path passed to docker here
# is a path inside a container, so that rewrite is always wrong.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) export MSYS_NO_PATHCONV=1 ;;
esac

if [[ $# -eq 0 ]]; then
    cat <<'USAGE'
Usage: ./scripts/occ.sh <command> [args...]

Commonly needed:

  status                          is it installed, what version, maintenance?
  check                           configuration problems Nextcloud can detect
  user:list                       accounts
  user:resetpassword <user>       change a password
  app:list                        installed apps and versions
  files:scan --all                reconcile the database with what is on disk
  files:cleanup                   remove filecache rows for files that are gone
  db:add-missing-indices          add indexes a version upgrade introduced
  db:add-missing-columns
  maintenance:mode --on|--off     take the instance offline
  maintenance:repair              run repair steps
  integrity:check-core            verify core files against upstream signatures
  config:list system              current configuration (redacts secrets)

Anything occ accepts works. `./scripts/occ.sh list` shows the full set.
USAGE
    exit 2
fi

docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx app \
    || { printf 'ERROR: the app service is not running. Run: make up\n' >&2; exit 1; }

# --user www-data is the entire point of this wrapper.
#
# -T disables TTY allocation, which keeps output pipeable and stops occ
# emitting terminal control sequences into a log. Interactive occ commands
# (user:add prompting for a password) need a TTY, so those are the exception
# and are handled by dropping -T.
case "${1}" in
    user:add|user:resetpassword|encryption:*|maintenance:data-fingerprint)
        # These prompt. Give them a TTY.
        exec docker compose exec --user www-data app php occ "$@"
        ;;
    *)
        exec docker compose exec --user www-data -T app php occ "$@"
        ;;
esac
