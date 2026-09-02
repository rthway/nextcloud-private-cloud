#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Linting: shell, Dockerfile, YAML.
#
# Linters run in containers rather than as host tools, so the same versions
# apply on a laptop and in CI. A lint failure that only reproduces on one
# machine is worse than no lint at all.
# ---------------------------------------------------------------------------
set -uo pipefail

# Declared and assigned separately: `readonly x="$(cmd)"` discards the
# command's exit status, so a failing cd would leave REPO_ROOT empty and
# the script would carry on operating relative to the wrong directory.
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

# Pull the linter images up front and quietly. Without this the first run's
# pull progress is captured as command output and reported as a lint failure.
readonly LINT_IMAGES=(
    koalaman/shellcheck:v0.10.0
    hadolint/hadolint:v2.12.0-alpine
    cytopia/yamllint:latest
)
printf 'preparing linter images'
for img in "${LINT_IMAGES[@]}"; do
    docker image inspect "${img}" >/dev/null 2>&1 || docker pull -q "${img}" >/dev/null 2>&1
    printf '.'
done
printf ' done
'

PASS=0
FAIL=0
pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --- Shell -----------------------------------------------------------------
head_ "ShellCheck"

shell_files=$(git ls-files '*.sh' 2>/dev/null || find . -name '*.sh' -not -path './.git/*')

for f in ${shell_files}; do
    # bash -n first: a syntax error produces clearer output than ShellCheck's.
    if ! bash -n "${f}" 2>/dev/null; then
        fail "syntax error: ${f}"
        bash -n "${f}" 2>&1 | sed 's/^/        /'
        continue
    fi

    # -S warning: style suggestions are advisory, warnings and errors are not.
    # -x follows `source` so that sourced files are analysed too.
    out=$(docker run --rm -v "${HOST_ROOT}:/mnt:ro" -w /mnt \
        koalaman/shellcheck:v0.10.0 -S warning -x "${f}" 2>&1)
    if [[ -z "${out}" ]]; then
        pass "${f}"
    else
        fail "${f}"
        sed 's/^/        /' <<<"${out}" | head -20
    fi
done

# Executable bits matter: a script committed without one fails in CI with a
# permission error that reads like a path problem.
head_ "Executable bits"
for f in ${shell_files}; do
    mode=$(git ls-files -s "${f}" 2>/dev/null | awk '{print $1}')
    if [[ "${mode}" == "100755" ]]; then
        pass "executable: ${f}"
    elif [[ -z "${mode}" ]]; then
        pass "untracked (skipped): ${f}"
    else
        fail "not executable in git (mode ${mode}): ${f} -- run: git update-index --chmod=+x ${f}"
    fi
done

# --- Dockerfile ------------------------------------------------------------
head_ "hadolint"

for f in $(git ls-files '*Dockerfile*' 2>/dev/null); do
    out=$(docker run --rm -i -v "${HOST_ROOT}/.hadolint.yaml:/.hadolint.yaml:ro" \
        hadolint/hadolint:v2.12.0-alpine hadolint --config /.hadolint.yaml - < "${f}" 2>&1)
    if [[ -z "${out}" ]]; then
        pass "${f}"
    else
        fail "${f}"
        sed 's/^/        /' <<<"${out}" | head -20
    fi
done

# --- YAML ------------------------------------------------------------------
head_ "yamllint"

yaml_out=$(docker run --rm -v "${HOST_ROOT}:/data:ro" -w /data \
    cytopia/yamllint:latest -c .yamllint . 2>&1)
if [[ -z "${yaml_out}" ]]; then
    pass "all YAML files"
else
    # yamllint reports warnings and errors; only errors should fail the build.
    if grep -q 'error' <<<"${yaml_out}"; then
        fail "yamllint reported errors"
        grep 'error' <<<"${yaml_out}" | sed 's/^/        /' | head -20
    else
        pass "all YAML files (warnings only)"
        sed 's/^/        /' <<<"${yaml_out}" | head -10
    fi
fi

# --- Markdown links --------------------------------------------------------
# A documentation link that 404s is a small thing until it is the runbook
# link someone follows during an incident.
head_ "Internal documentation links"

broken=0
while IFS= read -r line; do
    src="${line%%:*}"
    target="${line#*:}"
    dir=$(dirname "${src}")
    resolved=$(cd "${dir}" 2>/dev/null && python -c "
import os, sys
print(os.path.normpath(sys.argv[1]))" "${target}" 2>/dev/null)
    [[ -z "${resolved}" ]] && continue
    if [[ ! -e "${dir}/${target}" && ! -e "${resolved}" ]]; then
        fail "broken link in ${src} -> ${target}"
        broken=$(( broken + 1 ))
    fi
done < <(
    for md in $(git ls-files '*.md' 2>/dev/null); do
        # Relative markdown links only: skip http(s), anchors and mailto.
        grep -oE '\]\([^)#][^)]*\)' "${md}" 2>/dev/null \
            | sed 's/^](//; s/)$//' \
            | grep -vE '^(https?://|mailto:|#)' \
            | sed "s|^|${md}:|"
    done | tr -d '\r'
)
[[ ${broken} -eq 0 ]] && pass "all relative documentation links resolve"

# --- Result ----------------------------------------------------------------
printf '\n\033[1mLint: %d passed, %d failed\033[0m\n\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
