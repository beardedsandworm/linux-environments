#!/usr/bin/env bash
set -Eeuo pipefail

LOG_PREFIX="[system-update]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-$REPO_ROOT/scripts/notify.sh}"
ROOT_HELPER="${SYSTEM_UPDATE_ROOT_HELPER:-/usr/local/libexec/wormlogic/system-update-root}"
AUR_SUDO="${SYSTEM_UPDATE_AUR_SUDO:-/usr/local/bin/wormlogic-update-sudo}"
REBOOT_REQUIRED_FILE="${SYSTEM_UPDATE_REBOOT_REQUIRED_FILE:-/var/run/reboot-required}"
RUNNING_MODULES_DIR="${SYSTEM_UPDATE_RUNNING_MODULES_DIR:-/usr/lib/modules/$(uname -r)}"
MACHINE_ID_FILE="${MACHINE_ID_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id}"
if [[ -s "$MACHINE_ID_FILE" ]]; then
  MACHINE_ID="$(tr -d '\r\n[:space:]' <"$MACHINE_ID_FILE")"
else
  MACHINE_ID="$(hostname 2>/dev/null || printf 'unknown-host')"
fi
BEFORE="$(mktemp)"
AFTER="$(mktemp)"
DISTRO="unsupported"
STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

declare -A REMAINING_BY_MANAGER=()
declare -a REMAINING_PROBE_ERRORS=()
declare -a APPLIED_PROBE_ERRORS=()

printf '%s Starting system update...\n' "$LOG_PREFIX"

run_root() {
  sudo -n "$ROOT_HELPER" "$@"
}

detect_distro() {
  if command -v pacman >/dev/null 2>&1; then
    printf 'arch\n'
  elif command -v apt-get >/dev/null 2>&1; then
    printf 'ubuntu\n'
  else
    printf 'unsupported\n'
  fi
}

package_inventory() {
  local phase="$1" output

  case "$DISTRO" in
    ubuntu)
      if output="$(dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null)"; then
        printf '%s\n' "$output" | awk -F '\t' 'NF {print "apt:" $1 "\t" $2}'
      else
        APPLIED_PROBE_ERRORS+=("${phase}:apt")
      fi
      ;;
    arch)
      if output="$(pacman -Q 2>/dev/null)"; then
        printf '%s\n' "$output" | awk 'NF {name=$1; $1=""; sub(/^ /, ""); print "pacman:" name "\t" $0}'
      else
        APPLIED_PROBE_ERRORS+=("${phase}:pacman")
      fi
      ;;
  esac

  if command -v snap >/dev/null 2>&1; then
    if output="$(snap list 2>/dev/null)"; then
      printf '%s\n' "$output" | awk 'NR > 1 && NF {print "snap:" $1 "\t" $2 ":" $3}'
    else
      APPLIED_PROBE_ERRORS+=("${phase}:snap")
    fi
  fi
  if command -v flatpak >/dev/null 2>&1; then
    if output="$(flatpak list --columns=installation,ref,active 2>/dev/null)"; then
      printf '%s\n' "$output" | awk -F '\t' 'NF {print "flatpak:" $1 ":" $2 "\t" $3}'
    else
      APPLIED_PROBE_ERRORS+=("${phase}:flatpak")
    fi
  fi
  if command -v brew >/dev/null 2>&1; then
    if output="$(brew list --versions 2>/dev/null)"; then
      printf '%s\n' "$output" | awk 'NF {name=$1; $1=""; sub(/^ /, ""); print "brew:" name "\t" $0}'
    else
      APPLIED_PROBE_ERRORS+=("${phase}:brew")
    fi
  fi
}

inventory_diff_json() {
  local probe_errors="$1"
  python3 - "$BEFORE" "$AFTER" "$probe_errors" <<'PY'
import collections
import json
import sys


def load(path):
    result = {}
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.rstrip("\n")
            if not raw:
                continue
            key, _, version = raw.partition("\t")
            result[key] = version
    return result

before = load(sys.argv[1])
after = load(sys.argv[2])
probe_errors = json.loads(sys.argv[3])
counts = collections.Counter()
for key, version in after.items():
    if key not in before or before[key] != version:
        counts[key.split(":", 1)[0]] += 1
result = dict(counts)
for error in probe_errors:
    result[error.split(":", 1)[1]] = None
print(json.dumps(dict(sorted(result.items())), separators=(",", ":")))
PY
}

applied_probe_errors_json() {
  printf '%s\n' "${APPLIED_PROBE_ERRORS[@]}" | python3 -c 'import json,sys; print(json.dumps([line.strip() for line in sys.stdin if line.strip()], separators=(",", ":")))'
}

count_nonempty_lines() {
  awk 'NF {count++} END {print count + 0}'
}

collect_remaining_updates() {
  local output status
  REMAINING_BY_MANAGER=()
  REMAINING_PROBE_ERRORS=()

  case "$DISTRO" in
    ubuntu)
      if output="$(apt-get -s upgrade 2>/dev/null)"; then
        REMAINING_BY_MANAGER[apt]="$(printf '%s\n' "$output" | awk '/^Inst / {count++} END {print count + 0}')"
      else
        REMAINING_BY_MANAGER[apt]=null
        REMAINING_PROBE_ERRORS+=(apt)
      fi
      ;;
    arch)
      if command -v checkupdates >/dev/null 2>&1; then
        output="$(checkupdates 2>/dev/null)" && status=0 || status=$?
        if ((status == 0 || status == 2)); then
          REMAINING_BY_MANAGER[pacman]="$(printf '%s\n' "$output" | count_nonempty_lines)"
        else
          REMAINING_BY_MANAGER[pacman]=null
          REMAINING_PROBE_ERRORS+=(pacman)
        fi
      elif output="$(pacman -Qu 2>/dev/null)"; then
        REMAINING_BY_MANAGER[pacman]="$(printf '%s\n' "$output" | count_nonempty_lines)"
      else
        REMAINING_BY_MANAGER[pacman]=null
        REMAINING_PROBE_ERRORS+=(pacman)
      fi
      if command -v yay >/dev/null 2>&1; then
        output="$(yay -Qua 2>/dev/null)" && status=0 || status=$?
        if ((status == 0 || status == 1)); then
          REMAINING_BY_MANAGER[aur]="$(printf '%s\n' "$output" | count_nonempty_lines)"
        else
          REMAINING_BY_MANAGER[aur]=null
          REMAINING_PROBE_ERRORS+=(aur)
        fi
      fi
      ;;
  esac

  if command -v snap >/dev/null 2>&1; then
    if output="$(snap refresh --list 2>/dev/null)"; then
      REMAINING_BY_MANAGER[snap]="$(printf '%s\n' "$output" | awk 'NR > 1 && NF {count++} END {print count + 0}')"
    else
      REMAINING_BY_MANAGER[snap]=null
      REMAINING_PROBE_ERRORS+=(snap)
    fi
  fi
  if command -v flatpak >/dev/null 2>&1; then
    if output="$(flatpak remote-ls --updates --columns=application 2>/dev/null)"; then
      REMAINING_BY_MANAGER[flatpak]="$(printf '%s\n' "$output" | count_nonempty_lines)"
    else
      REMAINING_BY_MANAGER[flatpak]=null
      REMAINING_PROBE_ERRORS+=(flatpak)
    fi
  fi
  if command -v brew >/dev/null 2>&1; then
    if output="$(brew outdated --quiet 2>/dev/null)"; then
      REMAINING_BY_MANAGER[brew]="$(printf '%s\n' "$output" | count_nonempty_lines)"
    else
      REMAINING_BY_MANAGER[brew]=null
      REMAINING_PROBE_ERRORS+=(brew)
    fi
  fi
}

remaining_json() {
  local manager
  for manager in "${!REMAINING_BY_MANAGER[@]}"; do
    printf '%s=%s\n' "$manager" "${REMAINING_BY_MANAGER[$manager]}"
  done | python3 -c 'import json,sys; pairs={}; [(pairs.__setitem__(k, None if v == "null" else int(v))) for k,v in (line.strip().split("=",1) for line in sys.stdin if line.strip())]; print(json.dumps(dict(sorted(pairs.items())), separators=(",", ":")))'
}

probe_errors_json() {
  printf '%s\n' "${REMAINING_PROBE_ERRORS[@]}" | python3 -c 'import json,sys; print(json.dumps([line.strip() for line in sys.stdin if line.strip()], separators=(",", ":")))'
}

reboot_required() {
  case "$DISTRO" in
    ubuntu) [[ -f "$REBOOT_REQUIRED_FILE" ]] ;;
    arch) [[ ! -d "$RUNNING_MODULES_DIR" ]] ;;
    *) return 1 ;;
  esac
}

send_update_result() {
  local update_status="$1"
  local applied_json applied_probe_errors remaining_by_manager_json probe_errors applied_total remaining_total reboot completed_at
  local kind severity state event_type title summary details_json notify_status applied_phrase remaining_phrase reboot_phrase

  applied_probe_errors="$(applied_probe_errors_json)"
  applied_json="$(inventory_diff_json "$applied_probe_errors")"
  if ((${#APPLIED_PROBE_ERRORS[@]} > 0)); then
    applied_total=null
    applied_phrase="applied update count unknown"
  else
    applied_total="$(python3 -c 'import json,sys; print(sum(json.loads(sys.argv[1]).values()))' "$applied_json")"
    applied_phrase="${applied_total} update(s) applied"
  fi
  collect_remaining_updates
  remaining_by_manager_json="$(remaining_json)"
  probe_errors="$(probe_errors_json)"
  if ((${#REMAINING_PROBE_ERRORS[@]} > 0)); then
    remaining_total=null
    remaining_phrase="remaining update count unknown"
  else
    remaining_total="$(python3 -c 'import json,sys; print(sum(json.loads(sys.argv[1]).values()))' "$remaining_by_manager_json")"
    remaining_phrase="${remaining_total} remain"
  fi
  if reboot_required; then
    reboot=true
    reboot_phrase="reboot required"
  else
    reboot=false
    reboot_phrase="no reboot required"
  fi
  completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  if ((update_status != 0)); then
    kind="incident"
    severity="error"
    state="open"
    event_type="system_update.failed"
    title="System Update Failed"
    summary="${applied_phrase} before failure; ${remaining_phrase}; exit ${update_status}."
  elif ((${#APPLIED_PROBE_ERRORS[@]} > 0 || ${#REMAINING_PROBE_ERRORS[@]} > 0)); then
    kind="report"
    severity="warning"
    state="observed"
    event_type="system_update.result_incomplete"
    title="System Update Result Incomplete"
    summary="${applied_phrase}; ${remaining_phrase}; ${reboot_phrase}."
  elif [[ "$reboot" == true ]]; then
    kind="report"
    severity="warning"
    state="observed"
    event_type="system_update.reboot_required"
    title="System Update Completed — Reboot Required"
    summary="${applied_phrase}; ${remaining_phrase}; reboot required."
  else
    kind="report"
    severity="info"
    state="observed"
    event_type="system_update.completed"
    title="System Update Completed"
    summary="${applied_phrase}; ${remaining_phrase}; no reboot required."
  fi

  details_json="$(python3 - "$applied_json" "$applied_probe_errors" "$remaining_by_manager_json" "$probe_errors" "$applied_total" "$remaining_total" "$reboot" "$update_status" "$DISTRO" "$STARTED_AT" "$completed_at" <<'PY'
import json
import sys

applied, applied_probe_errors, remaining, remaining_probe_errors, applied_total, remaining_total, reboot, status, distro, started, completed = sys.argv[1:]
print(json.dumps({
    "updates_applied": None if applied_total == "null" else int(applied_total),
    "updates_applied_by_manager": json.loads(applied),
    "applied_probe_errors": json.loads(applied_probe_errors),
    "updates_remaining": None if remaining_total == "null" else int(remaining_total),
    "updates_remaining_by_manager": json.loads(remaining),
    "remaining_probe_errors": json.loads(remaining_probe_errors),
    "reboot_required": reboot == "true",
    "update_exit_status": int(status),
    "distribution": distro,
    "started_at": started,
    "completed_at": completed,
}, separators=(",", ":"), sort_keys=True))
PY
)"

  if "$NOTIFY_SCRIPT" \
    --producer "linux-environments.system-update" \
    --kind "$kind" \
    --domain host \
    --event-type "$event_type" \
    --severity "$severity" \
    --state "$state" \
    --dedupe-key "system-update:${MACHINE_ID}" \
    --title "$title" \
    --summary "$summary" \
    --details-json "$details_json"; then
    notify_status=0
  else
    notify_status=$?
  fi
  return "$notify_status"
}

on_exit() {
  local update_status="$?" notify_status=0
  trap - EXIT
  set +e

  package_inventory after >"$AFTER" || true
  send_update_result "$update_status"
  notify_status=$?
  rm -f "$BEFORE" "$AFTER"

  if ((update_status != 0)); then
    exit "$update_status"
  fi
  exit "$notify_status"
}
trap on_exit EXIT

DISTRO="$(detect_distro)"
printf '%s Distro: %s\n' "$LOG_PREFIX" "$DISTRO"
[[ -x "$ROOT_HELPER" ]] || { printf '%s Missing privileged update helper: %s\n' "$LOG_PREFIX" "$ROOT_HELPER" >&2; exit 1; }
[[ -x "$NOTIFY_SCRIPT" ]] || { printf '%s Missing notification transport: %s\n' "$LOG_PREFIX" "$NOTIFY_SCRIPT" >&2; exit 1; }
[[ "$DISTRO" != unsupported ]] || { printf '%s Unsupported system\n' "$LOG_PREFIX" >&2; exit 1; }
package_inventory before >"$BEFORE"

update_arch() {
  command -v yay >/dev/null 2>&1 || { printf '%s yay is required\n' "$LOG_PREFIX" >&2; return 1; }
  [[ -x "$AUR_SUDO" ]] || { printf '%s Missing AUR privilege helper\n' "$LOG_PREFIX" >&2; return 1; }

  printf '%s Creating pre-update Timeshift snapshot...\n' "$LOG_PREFIX"
  run_root timeshift-pre-update

  printf '%s Updating Arch repository and AUR packages...\n' "$LOG_PREFIX"
  yay -Syu \
    --noconfirm \
    --answerclean None \
    --answerdiff None \
    --answeredit None \
    --answerupgrade None \
    --sudo "$AUR_SUDO"

  if command -v flatpak >/dev/null 2>&1; then
    printf '%s Updating Flatpak packages...\n' "$LOG_PREFIX"
    flatpak update -y
  fi
}

update_ubuntu() {
  printf '%s Updating apt packages...\n' "$LOG_PREFIX"
  run_root apt-get

  if command -v snap >/dev/null 2>&1; then
    printf '%s Refreshing snap packages...\n' "$LOG_PREFIX"
    run_root snap
  fi
  if command -v flatpak >/dev/null 2>&1; then
    printf '%s Updating Flatpak packages...\n' "$LOG_PREFIX"
    flatpak update -y
  fi
  if command -v brew >/dev/null 2>&1; then
    printf '%s Updating Homebrew packages...\n' "$LOG_PREFIX"
    brew update
    brew upgrade
  fi
}

case "$DISTRO" in
  arch) update_arch ;;
  ubuntu) update_ubuntu ;;
esac

printf '%s System update complete\n' "$LOG_PREFIX"
