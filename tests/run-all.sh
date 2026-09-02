#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run the full test suite.
#
# Ordered cheapest-first, so a syntax error is reported in seconds rather than
# after a five-minute image scan. Every suite runs even if an earlier one
# fails -- reporting one problem at a time turns a single fix cycle into four.
#
#   ./tests/run-all.sh              # everything runnable in this environment
#   ./tests/run-all.sh --offline    # skip suites that need a running stack
#
# Suites:
#   lint      shell, Dockerfile, YAML, documentation links   (no stack needed)
#   config    compose, nginx, Odoo config, cross-file consistency (no stack)
#   security  secrets, filesystem and image scanning         (no stack needed)
#   smoke     the real request path end to end               (stack required)
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "${REPO_ROOT}" || exit 1

OFFLINE=0
[[ "${1:-}" == "--offline" ]] && OFFLINE=1

declare -a NAMES=()
declare -a RESULTS=()
declare -a DURATIONS=()

run_suite() {
    local name="$1"; shift
    local start finish rc

    printf '\n\033[1m========================================\033[0m\n'
    printf '\033[1m  %s\033[0m\n' "${name}"
    printf '\033[1m========================================\033[0m\n'

    start=$(date +%s)
    "$@"
    rc=$?
    finish=$(date +%s)

    NAMES+=("${name}")
    DURATIONS+=("$(( finish - start ))")
    if [[ ${rc} -eq 0 ]]; then RESULTS+=("pass"); else RESULTS+=("FAIL"); fi
    return 0
}

run_suite "Lint"          ./tests/test-lint.sh
run_suite "Configuration" ./tests/test-config.sh
run_suite "Security"      ./tests/test-security.sh --image

# The smoke suite needs a running stack. Skipping it silently would let a
# green run mean nothing, so the skip is recorded in the summary.
if [[ ${OFFLINE} -eq 1 ]]; then
    NAMES+=("Smoke"); RESULTS+=("skip"); DURATIONS+=("0")
elif docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx proxy; then
    run_suite "Smoke" ./tests/test-smoke.sh
else
    printf '\n\033[0;33mSmoke tests skipped: the stack is not running (make up).\033[0m\n'
    NAMES+=("Smoke"); RESULTS+=("skip"); DURATIONS+=("0")
fi

# --- Summary ---------------------------------------------------------------
printf '\n\033[1m========================================\033[0m\n'
printf '\033[1m  Summary\033[0m\n'
printf '\033[1m========================================\033[0m\n\n'

failed=0
skipped=0
for i in "${!NAMES[@]}"; do
    case "${RESULTS[i]}" in
        pass) printf '  \033[0;32mpass\033[0m  %-16s %3ss\n' "${NAMES[i]}" "${DURATIONS[i]}" ;;
        FAIL) printf '  \033[0;31mFAIL\033[0m  %-16s %3ss\n' "${NAMES[i]}" "${DURATIONS[i]}"; failed=$(( failed + 1 )) ;;
        skip) printf '  \033[0;33mskip\033[0m  %-16s      (stack not running)\n' "${NAMES[i]}"; skipped=$(( skipped + 1 )) ;;
    esac
done

echo
if [[ ${failed} -eq 0 && ${skipped} -eq 0 ]]; then
    printf '\033[0;32mAll suites passed.\033[0m\n\n'
elif [[ ${failed} -eq 0 ]]; then
    printf '\033[0;33mAll executed suites passed; %d skipped.\033[0m\n' "${skipped}"
    printf 'Run `make up && make init` and re-run to exercise the smoke tests.\n\n'
else
    printf '\033[0;31m%d suite(s) failed.\033[0m\n\n' "${failed}"
fi

[[ ${failed} -eq 0 ]]
