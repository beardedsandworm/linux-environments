#!/usr/bin/env bash
set -euo pipefail

[[ "$EUID" -eq 0 ]] || {
  echo "ERROR: system-update-root must run as root" >&2
  exit 1
}

action="${1:-}"
shift || true

case "$action" in
  validate)
    exit 0
    ;;

  timeshift)
    command -v timeshift >/dev/null 2>&1 || {
      echo "ERROR: timeshift is not installed" >&2
      exit 1
    }

    exec timeshift \
      --create \
      --comments "pre-system-update" \
      --tags D
    ;;

  pacman)
    exec /usr/bin/pacman "$@"
    ;;

  apt-get)
    export DEBIAN_FRONTEND=noninteractive

    /usr/bin/apt-get update
    exec /usr/bin/apt-get upgrade -y
    ;;

  snap)
    exec /usr/bin/snap refresh
    ;;

  *)
    echo "ERROR: unsupported privileged update action: $action" >&2
    exit 1
    ;;
esac
