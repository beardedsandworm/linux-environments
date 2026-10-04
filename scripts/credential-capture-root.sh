#!/usr/bin/env bash
set -euo pipefail

[[ "$EUID" -eq 0 ]] || {
  echo "ERROR: credential-capture-root must run as root" >&2
  exit 1
}

SSH_DIR="/etc/ssh"
WIREGUARD_DIR="/etc/wireguard"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

ssh_path() {
  local name="${1:-}"

  [[ "$name" =~ ^ssh_host_[A-Za-z0-9._+-]+_key$ ]] ||
    die "invalid SSH host-key name: $name"

  local path="$SSH_DIR/$name"

  [[ -f "$path" ]] ||
    die "SSH host key does not exist: $path"

  printf '%s\n' "$path"
}

wireguard_path() {
  local name="${1:-}"

  [[ "$name" =~ ^[A-Za-z0-9._@+-]+\.conf$ ]] ||
    die "invalid WireGuard configuration name: $name"

  local path="$WIREGUARD_DIR/$name"

  [[ -f "$path" ]] ||
    die "WireGuard configuration does not exist: $path"

  printf '%s\n' "$path"
}

action="${1:-}"
shift || true

case "$action" in
  validate)
    exit 0
    ;;

  ssh-list)
    [[ -d "$SSH_DIR" ]] || exit 0

    find "$SSH_DIR" \
      -maxdepth 1 \
      -type f \
      -name 'ssh_host_*_key' \
      -print0
    ;;

  ssh-cat)
    [[ "$#" -eq 1 ]] || die "ssh-cat requires one key name"
    cat -- "$(ssh_path "$1")"
    ;;

  ssh-hash)
    [[ "$#" -eq 1 ]] || die "ssh-hash requires one key name"
    sha256sum -- "$(ssh_path "$1")" | awk '{print $1}'
    ;;

  wireguard-list)
    [[ -d "$WIREGUARD_DIR" ]] || exit 0

    find "$WIREGUARD_DIR" \
      -maxdepth 1 \
      -type f \
      -name '*.conf' \
      -print0
    ;;

  wireguard-cat)
    [[ "$#" -eq 1 ]] || die "wireguard-cat requires one config name"
    cat -- "$(wireguard_path "$1")"
    ;;

  wireguard-hash)
    [[ "$#" -eq 1 ]] || die "wireguard-hash requires one config name"
    sha256sum -- "$(wireguard_path "$1")" | awk '{print $1}'
    ;;

  *)
    die "unsupported credential-capture action: $action"
    ;;
esac
