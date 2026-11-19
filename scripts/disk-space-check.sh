#!/usr/bin/env bash
set -Eeuo pipefail

LOG_PREFIX="[disk-space-check]"
THRESHOLD="${1:-85}"
NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-$HOME/dotfiles/scripts/notify.sh}"
MACHINE_ID_FILE="${MACHINE_ID_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id}"

if [[ ! "$THRESHOLD" =~ ^[0-9]+$ ]] || ((THRESHOLD < 1 || THRESHOLD > 100)); then
  printf '%s Invalid threshold: %s\n' "$LOG_PREFIX" "$THRESHOLD" >&2
  exit 2
fi
[[ -x "$NOTIFY_SCRIPT" ]] || {
  printf '%s Notification transport is not executable: %s\n' "$LOG_PREFIX" "$NOTIFY_SCRIPT" >&2
  exit 1
}

root_use="$(df -P / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
[[ "$root_use" =~ ^[0-9]+$ ]] || {
  printf '%s Could not determine root filesystem usage\n' "$LOG_PREFIX" >&2
  exit 1
}

printf '%s Root usage: %s%%\n' "$LOG_PREFIX" "$root_use"

if ((root_use >= THRESHOLD)); then
  if [[ -s "$MACHINE_ID_FILE" ]]; then
    machine_id="$(tr -d '\r\n[:space:]' <"$MACHINE_ID_FILE")"
  else
    machine_id="$(hostname 2>/dev/null || printf 'unknown-host')"
  fi
  details_json="$(printf '{\"mount\":\"/\",\"usage_percent\":%d,\"threshold_percent\":%d}' "$root_use" "$THRESHOLD")"
  "$NOTIFY_SCRIPT" \
    --producer "linux-environments.disk-space-check" \
    --kind incident \
    --domain storage \
    --event-type filesystem.capacity \
    --severity warning \
    --state open \
    --dedupe-key "filesystem:${machine_id}:/" \
    --title "Disk Space Warning" \
    --summary "Root filesystem on $(hostname) is at ${root_use}% usage." \
    --details-json "$details_json"
fi
