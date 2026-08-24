#!/usr/bin/env bash
set -euo pipefail

PVP_TABLE_ID="200"
PVP_TABLE_NAME="pvp"
PVP_SUBNET="10.9.0.0/24"
HOME_WG_SUBNET="10.8.0.0/24"
HOME_LAN_SUBNET="10.42.42.0/24"
PIHOLE_SUBNET="172.21.0.0/24"

RULE_HOME_WG="9900"
RULE_HOME_LAN="9910"
RULE_PIHOLE="9920"
RULE_PVP_DEFAULT="10000"

remove_rule_priority() {
  local priority="$1"
  while ip rule del priority "$priority" 2>/dev/null; do
    :
  done
}

ensure_loose_rp_filter() {
  local iface

  # Heighliner's working production state is loose reverse-path filtering (2).
  # Keep that state on interfaces that already exist rather than disabling it.
  for iface in eth0 wg0 wg-pvp wg-proton; do
    if ip link show "$iface" >/dev/null 2>&1; then
      sysctl -q -w "net.ipv4.conf.${iface}.rp_filter=2"
    fi
  done
}

apply_routes() {
  ip link show wg0 >/dev/null
  ip link show wg-pvp >/dev/null
  ip link show wg-proton >/dev/null

  ensure_loose_rp_filter

  ip route flush table "$PVP_TABLE_ID" 2>/dev/null || true

  # PVP clients themselves remain directly reachable in table 200.
  ip route replace "$PVP_SUBNET" dev wg-pvp table "$PVP_TABLE_ID"

  # Proton is the only Internet default in the PVP table.
  ip route replace default dev wg-proton metric 10 table "$PVP_TABLE_ID"

  # If Proton's default disappears, terminate lookup in this table rather than
  # falling through to Heighliner's normal eth0 default route.
  ip route replace unreachable default metric 32760 table "$PVP_TABLE_ID"

  # Private Wormlogic and Docker/Pi-hole destinations deliberately consult the
  # main table. wg0 and Docker remain authoritative for their own connected
  # routes; we do not duplicate those dynamic routes into table 200.
  remove_rule_priority "$RULE_HOME_WG"
  remove_rule_priority "$RULE_HOME_LAN"
  remove_rule_priority "$RULE_PIHOLE"
  remove_rule_priority "$RULE_PVP_DEFAULT"

  ip rule add priority "$RULE_HOME_WG" \
    from "$PVP_SUBNET" to "$HOME_WG_SUBNET" lookup main

  ip rule add priority "$RULE_HOME_LAN" \
    from "$PVP_SUBNET" to "$HOME_LAN_SUBNET" lookup main

  ip rule add priority "$RULE_PIHOLE" \
    from "$PVP_SUBNET" to "$PIHOLE_SUBNET" lookup main

  ip rule add priority "$RULE_PVP_DEFAULT" \
    from "$PVP_SUBNET" lookup "$PVP_TABLE_NAME"

  ip route flush cache 2>/dev/null || true
}

remove_routes() {
  remove_rule_priority "$RULE_HOME_WG"
  remove_rule_priority "$RULE_HOME_LAN"
  remove_rule_priority "$RULE_PIHOLE"
  remove_rule_priority "$RULE_PVP_DEFAULT"

  ip route flush table "$PVP_TABLE_ID" 2>/dev/null || true
  ip route flush cache 2>/dev/null || true
}

case "${1:-apply}" in
  apply)
    apply_routes
    ;;
  remove)
    remove_routes
    ;;
  *)
    echo "Usage: $0 [apply|remove]" >&2
    exit 2
    ;;
esac
