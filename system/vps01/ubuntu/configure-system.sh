#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_component() {
  local name="$1"
  local script="$2"

  if [[ ! -x "$script" ]]; then
    echo "✗ Missing or non-executable host component: $script"
    exit 1
  fi

  echo
  echo "=================================================="
  echo "Configuring: $name"
  echo "=================================================="

  "$script"
}

main() {
  echo "⚙ Configuring Heighliner system services..."

  # The base Wormlogic tunnel comes first. PVP relies on wg0/main-table
  # routes for access to 10.8.0.0/24 and the home LAN behind Midway.
  run_component \
    "Wormlogic WireGuard tunnel" \
    "$SCRIPT_DIR/wireguard/setup.sh"

  run_component \
    "PVP privacy gateway" \
    "$SCRIPT_DIR/pvp/setup.sh"

  echo
  echo "✓ Heighliner host-specific configuration complete"
}

main "$@"
