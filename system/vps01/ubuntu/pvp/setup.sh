#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SECRET_DIR="$REPO_ROOT/secrets/vps01"
PEER_DIR="$SCRIPT_DIR/peers"

WG_PVP_SECRET="$SECRET_DIR/wg-pvp.key.enc"
WG_PROTON_SECRET="$SECRET_DIR/wg-proton.conf.enc"
WG_PVP_EXPECTED_PUBLIC="$SCRIPT_DIR/heighliner.pub"
WG_PROTON_EXPECTED_PUBLIC="$SCRIPT_DIR/proton-client.pub"

WG_PVP_CONF="/etc/wireguard/wg-pvp.conf"
WG_PROTON_CONF="/etc/wireguard/wg-proton.conf"
WG_PVP_ADDRESS="10.9.0.1/24"
WG_PVP_PORT="51821"

TMP_DIR=""

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "✗ Required command not found: $1"
    exit 1
  }
}

require_file() {
  local file="$1"
  local description="$2"
  [[ -f "$file" ]] || {
    echo "✗ Missing $description: $file"
    exit 1
  }
}

decrypt_binary_secret() {
  local source_file="$1"
  local target_file="$2"

  sops --decrypt \
    --input-type json \
    --output-type binary \
    "$source_file" > "$target_file"
  chmod 600 "$target_file"
}

validate_peer_file() {
  local peer_file="$1"

  if ! grep -Eq '^[[:space:]]*\[Peer\][[:space:]]*$' "$peer_file"; then
    echo "✗ PVP peer file has no [Peer] section: $peer_file"
    exit 1
  fi

  if grep -Eq '^[[:space:]]*(PrivateKey|PresharedKey|Address|ListenPort|Endpoint)[[:space:]]*=' "$peer_file"; then
    echo "✗ PVP peer file contains secret/interface/dynamic endpoint material: $peer_file"
    exit 1
  fi
}

build_wg_pvp_config() {
  local private_key_file="$1"
  local output_file="$2"
  local -a peer_files=()

  shopt -s nullglob
  peer_files=("$PEER_DIR"/*.conf)
  shopt -u nullglob

  if ((${#peer_files[@]} == 0)); then
    echo "✗ No committed wg-pvp peer definitions found in $PEER_DIR"
    echo "  Run scripts/capture-vps01-wireguard-state.sh on the current Heighliner first."
    exit 1
  fi

  {
    echo "[Interface]"
    printf 'PrivateKey = %s\n' "$(<"$private_key_file")"
    echo "Address = $WG_PVP_ADDRESS"
    echo "ListenPort = $WG_PVP_PORT"

    local peer_file
    for peer_file in "${peer_files[@]}"; do
      validate_peer_file "$peer_file"
      echo
      cat "$peer_file"
    done
  } > "$output_file"

  chmod 600 "$output_file"
  wg-quick strip "$output_file" >/dev/null
}

validate_proton_config() {
  local config_file="$1"

  grep -Eq '^[[:space:]]*PrivateKey[[:space:]]*=' "$config_file" || {
    echo "✗ Proton config has no PrivateKey"
    exit 1
  }

  grep -Eq '^[[:space:]]*Table[[:space:]]*=[[:space:]]*off[[:space:]]*$' "$config_file" || {
    echo "✗ Proton config must contain 'Table = off'"
    exit 1
  }

  if grep -Eq '^[[:space:]]*DNS[[:space:]]*=' "$config_file"; then
    echo "✗ Proton config must not contain a DNS= line"
    exit 1
  fi

  grep -Eq '^[[:space:]]*AllowedIPs[[:space:]]*=.*0\.0\.0\.0/0' "$config_file" || {
    echo "✗ Proton config does not contain an IPv4 default AllowedIPs route"
    exit 1
  }

  wg-quick strip "$config_file" >/dev/null
}

private_key_from_config() {
  awk -F '[[:space:]]*=[[:space:]]*' \
    '/^[[:space:]]*PrivateKey[[:space:]]*=/ {print $2; exit}' "$1"
}

install_files() {
  local pvp_config_temp="$1"
  local proton_config_temp="$2"
  local pvp_public_temp="$3"
  local proton_public_temp="$4"

  sudo install -d -m 0700 /etc/wireguard
  sudo install -d -m 0755 /etc/nftables.d
  sudo install -d -m 0755 /usr/local/lib/wormlogic
  sudo install -d -m 0755 /etc/iproute2/rt_tables.d

  sudo install -m 0600 "$pvp_config_temp" "$WG_PVP_CONF"
  sudo install -m 0600 "$proton_config_temp" "$WG_PROTON_CONF"
  sudo install -m 0644 "$pvp_public_temp" /etc/wireguard/wg-pvp.public
  sudo install -m 0644 "$proton_public_temp" /etc/wireguard/wg-proton.public

  sudo install -m 0755 "$SCRIPT_DIR/pvp-routing.sh" /usr/local/lib/wormlogic/pvp-routing.sh
  sudo install -m 0644 "$SCRIPT_DIR/pvp.nft" /etc/nftables.d/wormlogic-pvp.nft
  sudo install -m 0644 "$SCRIPT_DIR/wormlogic-pvp.service" /etc/systemd/system/wormlogic-pvp.service

  printf '%s\n' '200 pvp' | sudo tee /etc/iproute2/rt_tables.d/200-pvp.conf >/dev/null
  sudo systemctl daemon-reload
}

sync_or_start_interface() {
  local interface="$1"
  local config_temp="$2"
  local address="$3"
  local stripped_temp="$4"

  sudo systemctl enable "wg-quick@${interface}.service"

  if systemctl is-active --quiet "wg-quick@${interface}.service"; then
    sudo wg syncconf "$interface" "$stripped_temp"

    if [[ -n "$address" ]] && ! ip -4 address show dev "$interface" | grep -Fq "$address"; then
      sudo ip address add "$address" dev "$interface"
    fi
  else
    sudo systemctl start "wg-quick@${interface}.service"
  fi
}

main() {
  echo "🔐 Configuring Heighliner PVP gateway..."

  for command_name in sops wg wg-quick ip nft sysctl systemctl awk; do
    require_command "$command_name"
  done

  require_file "$WG_PVP_SECRET" "encrypted wg-pvp private key"
  require_file "$WG_PROTON_SECRET" "encrypted Proton WireGuard config"
  require_file "$WG_PVP_EXPECTED_PUBLIC" "captured wg-pvp public identity"
  require_file "$WG_PROTON_EXPECTED_PUBLIC" "captured Proton client public identity"
  require_file "$SCRIPT_DIR/pvp-routing.sh" "PVP routing script"
  require_file "$SCRIPT_DIR/pvp.nft" "PVP nftables rules"
  require_file "$SCRIPT_DIR/wormlogic-pvp.service" "PVP systemd unit"

  if [[ "$(sysctl -n net.ipv4.ip_forward)" != "1" || \
        "$(sysctl -n net.ipv4.conf.all.rp_filter)" != "2" || \
        "$(sysctl -n net.ipv4.conf.default.rp_filter)" != "2" ]]; then
    echo "✗ Wormlogic routing sysctls are not in the expected state"
    echo "  wireguard/setup.sh must complete before PVP setup."
    exit 1
  fi

  TMP_DIR="$(mktemp -d)"
  chmod 700 "$TMP_DIR"

  local pvp_key_temp="$TMP_DIR/wg-pvp.key"
  local pvp_conf_temp="$TMP_DIR/wg-pvp.conf"
  local pvp_public_temp="$TMP_DIR/wg-pvp.public"
  local pvp_stripped_temp="$TMP_DIR/wg-pvp.stripped"
  local proton_conf_temp="$TMP_DIR/wg-proton.conf"
  local proton_public_temp="$TMP_DIR/wg-proton.public"
  local proton_stripped_temp="$TMP_DIR/wg-proton.stripped"

  decrypt_binary_secret "$WG_PVP_SECRET" "$pvp_key_temp"
  decrypt_binary_secret "$WG_PROTON_SECRET" "$proton_conf_temp"

  build_wg_pvp_config "$pvp_key_temp" "$pvp_conf_temp"
  validate_proton_config "$proton_conf_temp"

  wg pubkey < "$pvp_key_temp" > "$pvp_public_temp"
  private_key_from_config "$proton_conf_temp" | wg pubkey > "$proton_public_temp"
  chmod 644 "$pvp_public_temp" "$proton_public_temp"

  local pvp_expected proton_expected
  pvp_expected="$(tr -d '\r\n' < "$WG_PVP_EXPECTED_PUBLIC")"
  proton_expected="$(tr -d '\r\n' < "$WG_PROTON_EXPECTED_PUBLIC")"

  if [[ "$(<"$pvp_public_temp")" != "$pvp_expected" ]]; then
    echo "✗ Restored wg-pvp key does not match the captured Heighliner identity"
    exit 1
  fi

  if [[ "$(<"$proton_public_temp")" != "$proton_expected" ]]; then
    echo "✗ Restored Proton config does not match the captured client identity"
    exit 1
  fi

  wg-quick strip "$pvp_conf_temp" > "$pvp_stripped_temp"
  wg-quick strip "$proton_conf_temp" > "$proton_stripped_temp"
  chmod 600 "$pvp_stripped_temp" "$proton_stripped_temp"

  install_files "$pvp_conf_temp" "$proton_conf_temp" "$pvp_public_temp" "$proton_public_temp"

  sync_or_start_interface "wg-pvp" "$pvp_conf_temp" "$WG_PVP_ADDRESS" "$pvp_stripped_temp"
  sync_or_start_interface "wg-proton" "$proton_conf_temp" "" "$proton_stripped_temp"

  sudo systemctl enable wormlogic-pvp.service
  if systemctl is-active --quiet wormlogic-pvp.service; then
    sudo systemctl reload wormlogic-pvp.service
  else
    sudo systemctl start wormlogic-pvp.service
  fi

  echo "✓ PVP gateway ready"
  echo "  wg-pvp:    $WG_PVP_ADDRESS UDP/$WG_PVP_PORT"
  echo "  wg-proton: provider tunnel with Table=off"
  echo "  route table: 200 (pvp)"
  echo "  external requirement: provider firewall permits UDP/$WG_PVP_PORT"
}

main "$@"
