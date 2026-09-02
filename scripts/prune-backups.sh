#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Retention: grandfather-father-son.
#
# "Keep the last N backups" is not a retention policy. Corruption or a bad
# data migration discovered on Tuesday, after a long weekend of nightly
# backups, has already overwritten every copy of the good data. Keeping a
# weekly and a monthly line means the recovery window is measured in months
# for the cases that matter, without paying to store months of dailies.
#
# Retained:
#   * every backup from the last BACKUP_RETENTION_DAILY days
#   * the newest backup of each of the last BACKUP_RETENTION_WEEKLY ISO weeks
#   * the newest backup of each of the last BACKUP_RETENTION_MONTHLY months
#   * always, unconditionally, the single newest backup
#
#   ./scripts/prune-backups.sh              # delete
#   ./scripts/prune-backups.sh --dry-run    # report only
# ---------------------------------------------------------------------------
set -euo pipefail

# Declared and assigned separately: `readonly x="$(cmd)"` discards the
# command's exit status, so a failing cd would leave REPO_ROOT empty and
# the script would carry on operating relative to the wrong directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "${REPO_ROOT}" || exit 1

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ -f .env ]]; then
    # shellcheck disable=SC1091
    set -a; source .env; set +a
fi

: "${BACKUP_DIR:=./backups}"
: "${BACKUP_RETENTION_DAILY:=7}"
: "${BACKUP_RETENTION_WEEKLY:=4}"
: "${BACKUP_RETENTION_MONTHLY:=6}"

log()  { printf '\033[0;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m==> WARN:\033[0m %s\n' "$*" >&2; }

[[ -d "${BACKUP_DIR}" ]] || { log "no backup directory at ${BACKUP_DIR}; nothing to prune"; exit 0; }

# Backup directories are named YYYYMMDDTHHMMSSZ, so lexical sort is
# chronological sort. That is the entire reason for the naming scheme.
mapfile -t all_backups < <(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended -regex '.*/[0-9]{8}T[0-9]{6}Z$' -printf '%f\n' 2>/dev/null | sort)

if [[ ${#all_backups[@]} -eq 0 ]]; then
    log "no backups found in ${BACKUP_DIR}"
    exit 0
fi

log "found ${#all_backups[@]} backup(s)"

# --- Build the keep set ----------------------------------------------------
declare -A keep=()
declare -A reason=()

# The newest, always. Even if it is older than every retention window --
# an old backup is still infinitely better than none, and a policy that can
# delete the last copy is a policy with a bug in it.
newest="${all_backups[-1]}"
keep["${newest}"]=1
reason["${newest}"]="newest"

now_epoch="$(date -u +%s)"
daily_cutoff=$(( now_epoch - BACKUP_RETENTION_DAILY * 86400 ))

declare -A seen_week=()
declare -A seen_month=()

# Walk newest-first so that "the newest of each week" is simply the first one
# encountered for that week.
for (( idx=${#all_backups[@]}-1; idx>=0; idx-- )); do
    id="${all_backups[idx]}"

    # 20260902T101500Z -> 2026-09-02 10:15:00
    y="${id:0:4}"; m="${id:4:2}"; d="${id:6:2}"
    hh="${id:9:2}"; mm="${id:11:2}"; ss="${id:13:2}"

    if ! epoch="$(date -u -d "${y}-${m}-${d} ${hh}:${mm}:${ss}" +%s 2>/dev/null)"; then
        warn "cannot parse timestamp from '${id}'; keeping it rather than guessing"
        keep["${id}"]=1
        reason["${id}"]="unparseable name"
        continue
    fi

    # Daily window
    if [[ ${epoch} -ge ${daily_cutoff} ]]; then
        keep["${id}"]=1
        reason["${id}"]="within ${BACKUP_RETENTION_DAILY}-day daily window"
        continue
    fi

    # Weekly line: newest backup of each ISO week, for N weeks
    week_key="$(date -u -d "@${epoch}" +%G-W%V)"
    if [[ -z "${seen_week[${week_key}]:-}" ]]; then
        seen_week["${week_key}"]=1
        if [[ ${#seen_week[@]} -le ${BACKUP_RETENTION_WEEKLY} ]]; then
            keep["${id}"]=1
            reason["${id}"]="weekly ${week_key}"
            continue
        fi
    fi

    # Monthly line: newest backup of each month, for N months
    month_key="$(date -u -d "@${epoch}" +%Y-%m)"
    if [[ -z "${seen_month[${month_key}]:-}" ]]; then
        seen_month["${month_key}"]=1
        if [[ ${#seen_month[@]} -le ${BACKUP_RETENTION_MONTHLY} ]]; then
            keep["${id}"]=1
            reason["${id}"]="monthly ${month_key}"
            continue
        fi
    fi
done

# --- Apply -----------------------------------------------------------------
kept=0
deleted=0
freed=0

for id in "${all_backups[@]}"; do
    path="${BACKUP_DIR}/${id}"
    if [[ -n "${keep[${id}]:-}" ]]; then
        printf '  keep    %s  (%s)\n' "${id}" "${reason[${id}]}"
        kept=$(( kept + 1 ))
    else
        size_kb="$(du -sk "${path}" | cut -f1)"
        if [[ ${DRY_RUN} -eq 1 ]]; then
            printf '  DELETE  %s  (dry run, %s KiB)\n' "${id}" "${size_kb}"
        else
            printf '  delete  %s  (%s KiB)\n' "${id}" "${size_kb}"
            rm -rf "${path}"
        fi
        deleted=$(( deleted + 1 ))
        freed=$(( freed + size_kb ))
    fi
done

if [[ ${DRY_RUN} -eq 1 ]]; then
    log "dry run: would keep ${kept}, delete ${deleted}, free $(( freed / 1024 )) MiB"
else
    log "kept ${kept}, deleted ${deleted}, freed $(( freed / 1024 )) MiB"
fi
