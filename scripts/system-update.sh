#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[system-update]"
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
  run_root timeshift

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
