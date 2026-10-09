#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[system-update]"
HOST_WEBHOOK="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/discord-webhook"
ROOT_HELPER="/usr/local/libexec/wormlogic/system-update-root"
AUR_SUDO="/usr/local/bin/wormlogic-update-sudo"
GREEN=5763719
ORANGE=16753920
RED=15548997

# Compare installed package versions, not the number of available upgrades.
# Count dpkg/pacman packages only; snap, Flatpak and Homebrew still update as before.
BEFORE="$(mktemp)"
AFTER="$(mktemp)"
DISTRO="unsupported"
UPDATED=0

echo "$LOG_PREFIX Starting system update..."

run_root() {
  sudo -n "$ROOT_HELPER" "$@"
}

detect_distro() {
  if command -v pacman >/dev/null 2>&1; then
    echo arch
  elif command -v apt-get >/dev/null 2>&1; then
    echo ubuntu
  else
    echo unsupported
  fi
}

package_inventory() {
  case "$DISTRO" in
    ubuntu)
      dpkg-query -W -f='${binary:Package}\t${Version}\n' | LC_ALL=C sort
      ;;
    arch)
      pacman -Q | LC_ALL=C sort
      ;;
  esac
}

count_updates() {
  # Counts installed packages with a new version, as well as new dependencies.
  awk 'NR==FNR { old[$1]=$2; next } ($1 in old && old[$1] != $2) || !($1 in old) { count++ } END { print count+0 }' "$BEFORE" "$AFTER"
}

reboot_required() {
  case "$DISTRO" in
    ubuntu) [[ -f /var/run/reboot-required ]] ;;
    arch) [[ ! -d "/usr/lib/modules/$(uname -r)" ]] ;;
    *) return 1 ;;
  esac
}

notify_discord() {
  local color="$1" message="$2" host url payload
  if [[ ! -s "$HOST_WEBHOOK" ]] || ! command -v curl >/dev/null 2>&1; then
    echo "$LOG_PREFIX Discord webhook or curl unavailable; notification skipped" >&2
    return 0
  fi

  host="$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id" 2>/dev/null || hostname)"
  host="${host//$'\n'/}"
  host="${host//$'\r'/}"
  # Escape interpolated strings for JSON.
  host="${host//\\/\\\\}"
  host="${host//\"/\\\"}"
  message="${message//\\/\\\\}"
  message="${message//\"/\\\"}"
  url="$(tr -d '\r\n' < "$HOST_WEBHOOK")"
  payload="{\"embeds\":[{\"title\":\"System Update — ${host}\",\"description\":\"${message}\",\"color\":${color}}]}"
  if ! curl -fsS --connect-timeout 10 --max-time 20 -H 'Content-Type: application/json' -X POST --data "$payload" "$url" >/dev/null; then
    echo "$LOG_PREFIX Could not send Discord notification" >&2
  fi
}

on_exit() {
  local status="$1" color message
  trap - EXIT
  if [[ -s "$BEFORE" ]]; then
    if package_inventory > "$AFTER"; then
      UPDATED="$(count_updates)"
    fi
  fi
  rm -f "$BEFORE" "$AFTER"

  if (( status != 0 )); then
    color="$RED"
    message="${UPDATED} package(s) updated. Update failed (exit ${status})."
  elif reboot_required; then
    color="$ORANGE"
    message="${UPDATED} package(s) updated. Reboot required."
  elif (( UPDATED > 0 )); then
    color="$GREEN"
    message="${UPDATED} package(s) updated. No reboot required."
  else
    echo "$LOG_PREFIX No package changes, failure, or reboot requirement; no notification"
    return
  fi
  notify_discord "$color" "$message"
}
trap 'on_exit $?' EXIT

DISTRO="$(detect_distro)"
echo "$LOG_PREFIX Distro: $DISTRO"
[[ -x "$ROOT_HELPER" ]] || { echo "$LOG_PREFIX Missing privileged update helper: $ROOT_HELPER" >&2; exit 1; }
[[ "$DISTRO" != unsupported ]] || { echo "$LOG_PREFIX Unsupported system" >&2; exit 1; }
package_inventory > "$BEFORE"

update_arch() {
  command -v yay >/dev/null 2>&1 || { echo "$LOG_PREFIX yay is required" >&2; return 1; }
  [[ -x "$AUR_SUDO" ]] || { echo "$LOG_PREFIX Missing AUR privilege helper" >&2; return 1; }

  echo "$LOG_PREFIX Creating pre-update Timeshift snapshot..."
  run_root timeshift-pre-update

  echo "$LOG_PREFIX Updating Arch repository and AUR packages..."
  yay -Syu \
    --noconfirm \
    --answerclean None \
    --answerdiff None \
    --answeredit None \
    --answerupgrade None \
    --sudo "$AUR_SUDO"

  if command -v flatpak >/dev/null 2>&1; then
    echo "$LOG_PREFIX Updating Flatpak packages..."
    flatpak update -y
  else
    echo "$LOG_PREFIX flatpak not present, skipping"
  fi
}

update_ubuntu() {
  echo "$LOG_PREFIX Updating apt packages..."
  run_root apt-get

  if command -v snap >/dev/null 2>&1; then
    echo "$LOG_PREFIX Refreshing snap packages..."
    run_root snap
  else
    echo "$LOG_PREFIX snap not present, skipping"
  fi

  if command -v flatpak >/dev/null 2>&1; then
    echo "$LOG_PREFIX Updating Flatpak packages..."
    flatpak update -y
  else
    echo "$LOG_PREFIX flatpak not present, skipping"
  fi

  if command -v brew >/dev/null 2>&1; then
    echo "$LOG_PREFIX Updating Homebrew packages..."
    brew update
    brew upgrade
  else
    echo "$LOG_PREFIX brew not present, skipping"
  fi
}

case "$DISTRO" in
  arch) update_arch ;;
  ubuntu) update_ubuntu ;;
esac

echo "$LOG_PREFIX System update complete"
