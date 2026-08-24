#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SECRET_DIR="$REPO_ROOT/secrets/vps01"
PEER_DIR="$SCRIPT_DIR/peers"

WG0_SECRET="$SECRET_DIR/wg0.key.enc"
EXPECTED_PUBLIC_FILE="$SCRIPT_DIR/heighliner.pub"
WG0_CONF="/etc/wireguard/wg0.conf"
WG0_PUBLIC="/etc/wireguard/wg0.public"
WG0_ADDRESS="10.8.0.1/24"
WG0_PORT="51820"

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
    echo "✗ Peer file has no [Peer] section: $peer_file"
    exit 1
  fi

  if grep -Eq '^[[:space:]]*(PrivateKey|PresharedKey|Address|ListenPort|Endpoint)[[:space:]]*=' "$peer_file"; then
    echo "✗ Peer file contains secret/interface/dynamic endpoint material: $peer_file"
    exit 1
  fi
}

build_config() {
  local private_key_file="$1"
  local output_file="$2"
  local -a peer_files=()

  shopt -s nullglob
  peer_files=("$PEER_DIR"/*.conf)
  shopt -u nullglob

  if ((${#peer_files[@]} == 0)); then
    echo "✗ No Wormlogic peer definitions found in $PEER_DIR"
    exit 1
  fi

  {
    echo "[Interface]"
    printf 'PrivateKey = %s\n' "$(<"$private_key_file")"
    echo "Address = $WG0_ADDRESS"
    echo "ListenPort = $WG0_PORT"

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

install_files() {
  local config_temp="$1"
  local public_temp="$2"

  sudo install -d -m 0700 /etc/wireguard
  sudo install -d -m 0755 /etc/nftables.d

  sudo install -m 0600 "$config_temp" "$WG0_CONF"
  sudo install -m 0644 "$public_temp" "$WG0_PUBLIC"
  sudo install -m 0644 "$SCRIPT_DIR/sysctl.conf" /etc/sysctl.d/99-wormlogic-network.conf
  sudo install -m 0644 "$SCRIPT_DIR/wormlogic.nft" /etc/nftables.d/wormlogic-wg.nft
  sudo install -m 0644 "$SCRIPT_DIR/wormlogic-wg.service" /etc/systemd/system/wormlogic-wg.service

  sudo sysctl --system >/dev/null
  sudo systemctl daemon-reload
}

activate_wg0() {
  local stripped_temp="$1"

  sudo systemctl enable wg-quick@wg0.service

  if systemctl is-active --quiet wg-quick@wg0.service; then
    sudo wg syncconf wg0 "$stripped_temp"

    if ! ip -4 address show dev wg0 | grep -Fq '10.8.0.1/24'; then
      sudo ip address add "$WG0_ADDRESS" dev wg0
    fi
  else
    sudo systemctl start wg-quick@wg0.service
  fi

  sudo systemctl enable wormlogic-wg.service
  if systemctl is-active --quiet wormlogic-wg.service; then
    sudo systemctl reload wormlogic-wg.service
  else
    sudo systemctl start wormlogic-wg.service
  fi
}

main() {
  echo "🔐 Configuring Heighliner Wormlogic tunnel (wg0)..."

  for command_name in sops wg wg-quick ip nft systemctl; do
    require_command "$command_name"
  done

  require_file "$WG0_SECRET" "encrypted wg0 private key"
  require_file "$EXPECTED_PUBLIC_FILE" "expected Heighliner wg0 public key"
  require_file "$SCRIPT_DIR/sysctl.conf" "Wormlogic sysctl configuration"
  require_file "$SCRIPT_DIR/wormlogic.nft" "Wormlogic nftables rules"
  require_file "$SCRIPT_DIR/wormlogic-wg.service" "Wormlogic systemd unit"

  TMP_DIR="$(mktemp -d)"
  chmod 700 "$TMP_DIR"

  local key_temp="$TMP_DIR/wg0.key"
  local config_temp="$TMP_DIR/wg0.conf"
  local public_temp="$TMP_DIR/wg0.public"
  local stripped_temp="$TMP_DIR/wg0.stripped"

  decrypt_binary_secret "$WG0_SECRET" "$key_temp"
  wg pubkey < "$key_temp" > "$public_temp"
  chmod 644 "$public_temp"

  local actual_public expected_public
  actual_public="$(<"$public_temp")"
  expected_public="$(tr -d '\r\n' < "$EXPECTED_PUBLIC_FILE")"

  if [[ "$actual_public" != "$expected_public" ]]; then
    echo "✗ Restored wg0 private key does not match Heighliner's expected identity"
    echo "  Expected public key: $expected_public"
    echo "  Derived public key:  $actual_public"
    exit 1
  fi

  build_config "$key_temp" "$config_temp"
  wg-quick strip "$config_temp" > "$stripped_temp"
  chmod 600 "$stripped_temp"

  install_files "$config_temp" "$public_temp"
  activate_wg0 "$stripped_temp"

  if [[ "$(sudo wg show wg0 public-key)" != "$expected_public" ]]; then
    echo "✗ wg0 started with an unexpected public key"
    exit 1
  fi

  echo "✓ Wormlogic tunnel ready"
  echo "  Interface:  wg0"
  echo "  Address:    $WG0_ADDRESS"
  echo "  ListenPort: UDP/$WG0_PORT"
  echo "  Public key: $expected_public"
  echo "  External requirement: provider firewall permits UDP/$WG0_PORT"
}

main "$@"
