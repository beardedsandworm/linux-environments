#!/usr/bin/env bash
set -euo pipefail

ROOT_HELPER="/usr/local/libexec/wormlogic/system-update-root"

[[ -x "$ROOT_HELPER" ]] || {
  echo "ERROR: missing privileged update helper: $ROOT_HELPER" >&2
  exit 1
}

sudo -n "$ROOT_HELPER" timeshift-weekly
