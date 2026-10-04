#!/usr/bin/env bash
set -euo pipefail

ROOT_HELPER="/usr/local/libexec/wormlogic/system-update-root"

case "${1:-}" in
  -v|--validate)
    exec sudo -n "$ROOT_HELPER" validate
    ;;
  -k|-K)
    exit 0
    ;;
esac

if [[ "${1:-}" == "-n" ]]; then
  shift
fi

if [[ "${1:-}" == "pacman" || "${1:-}" == "/usr/bin/pacman" ]]; then
  shift
fi

exec sudo -n "$ROOT_HELPER" pacman "$@"
