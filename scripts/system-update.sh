#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[system-update]"
HOST_WEBHOOK="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/discord-webhook"
REBOOT_COLOR=16753920  # #FFA500
ROOT_HELPER="/usr/local/libexec/wormlogic/system-update-root"
AUR_SUDO="/usr/local/bin/wormlogic-update-sudo"

echo "$LOG_PREFIX Starting system update..."

die() {
  echo "$LOG_PREFIX ERROR: $*" >&2
  exit 1
}

run_root() {
  sudo -n "$ROOT_HELPER" "$@"
}

detect_distro() {
  if command -v pacman >/dev/null 2>&1; then
    echo "arch"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "ubuntu"
  else
    echo "unsupported"
  fi
}

[[ -x "$ROOT_HELPER" ]] ||
  die "Missing privileged update helper: $ROOT_HELPER"

DISTRO="$(detect_distro)"

echo "$LOG_PREFIX Distro: $DISTRO"

update_arch() {
  command -v yay >/dev/null 2>&1 ||
    die "yay is required for scheduled Arch updates"

  [[ -x "$AUR_SUDO" ]] ||
    die "Missing AUR privilege helper: $AUR_SUDO"

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

notify_reboot_required() {
  local host

  [[ -s "$HOST_WEBHOOK" ]] || {
    echo "$LOG_PREFIX Reboot required, but host Discord webhook is unavailable"
    return 0
  }

  command -v curl >/dev/null 2>&1 || {
    echo "$LOG_PREFIX Reboot required, but curl is unavailable"
    return 0
  }

  host="$(tr -d '\r\n' < "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id" 2>/dev/null || hostname)"

  curl -fsS \
    -H 'Content-Type: application/json' \
    -X POST \
    --data @- \
    "$(tr -d '\r\n' < "$HOST_WEBHOOK")" <<EOF
{
  "embeds": [
    {
      "title": "Restart Required",
      "description": "**${host}** requires a restart after system updates.",
      "color": ${REBOOT_COLOR}
    }
  ]
}
EOF

  echo "$LOG_PREFIX Restart-required notification sent"
}

reboot_required() {
  case "$DISTRO" in
    ubuntu)
      [[ -f /var/run/reboot-required ]]
      ;;

    arch)
      [[ ! -d "/usr/lib/modules/$(uname -r)" ]]
      ;;

    *)
      return 1
      ;;
  esac
}

case "$DISTRO" in
  arch)
    update_arch
    ;;
  ubuntu)
    update_ubuntu
    ;;
  *)
    die "Unsupported system"
    ;;
esac

echo "$LOG_PREFIX System update complete"

if reboot_required; then
  echo "$LOG_PREFIX Restart required"
  notify_reboot_required
else
  echo "$LOG_PREFIX No restart required"
fi
