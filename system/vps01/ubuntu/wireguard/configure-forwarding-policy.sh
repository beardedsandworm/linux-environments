#!/usr/bin/env bash
set -euo pipefail

EXPECTED_RULE="ufw route allow in on wg0 out on wg0 from 10.8.0.6 to 10.8.0.3 port 443 proto tcp"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "✗ Required command not found: $1" >&2
    exit 1
  }
}

ufw_c() {
  sudo /usr/bin/env LC_ALL=C ufw "$@"
}

require_active_ufw() {
  local status
  status="$(ufw_c status)"

  if ! grep -Fxq 'Status: active' <<< "$status"; then
    echo "✗ UFW must be active before changing Wormlogic forwarding policy" >&2
    exit 1
  fi
}

converge_ufw_policy() {
  local rules

  if ! sudo grep -Fxq 'DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw; then
    echo "✗ UFW routed default must already be deny before policy reconciliation" >&2
    exit 1
  fi

  sudo ufw route allow in on wg0 out on wg0 proto tcp from 10.8.0.6 to 10.8.0.3 port 443 \
    comment 'Farcaster to Arrakis HTTPS'

  rules="$(ufw_c show added)"
  if ! grep -Fq "$EXPECTED_RULE" <<< "$rules"; then
    echo "✗ UFW did not retain the Farcaster-to-Arrakis forwarding rule" >&2
    exit 1
  fi
}

remove_legacy_forwarding_policy() {
  if systemctl is-active --quiet wormlogic-wg.service ||
     systemctl is-enabled --quiet wormlogic-wg.service 2>/dev/null; then
    sudo systemctl disable --now wormlogic-wg.service
  fi

  sudo rm -f \
    /etc/systemd/system/wormlogic-wg.service \
    /etc/nftables.d/wormlogic-wg.nft

  if sudo nft list table inet wormlogic_wg_filter >/dev/null 2>&1; then
    sudo nft delete table inet wormlogic_wg_filter
  fi

  sudo systemctl daemon-reload
}

main() {
  local command_name
  for command_name in grep nft sudo systemctl ufw; do
    require_command "$command_name"
  done

  require_active_ufw
  converge_ufw_policy
  remove_legacy_forwarding_policy

  echo "✓ UFW has the managed Farcaster HTTPS forwarding rule for Arrakis on wg0"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
