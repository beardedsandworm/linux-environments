#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIREGUARD_STATE_DIR="${WIREGUARD_CREDENTIAL_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/wireguard}"
PEER_DIR="$SCRIPT_DIR/peers"

WG_PVP_RECOVERED_CONF="$WIREGUARD_STATE_DIR/wg-pvp.conf"
WG_PVP_RECOVERED_PUBLIC="$WIREGUARD_STATE_DIR/wg-pvp.public-key"
WG_PROTON_RECOVERED_CONF="$WIREGUARD_STATE_DIR/wg-proton.conf"
WG_PROTON_RECOVERED_PUBLIC="$WIREGUARD_STATE_DIR/wg-proton.public-key"

WG_PVP_EXPECTED_PUBLIC="$SCRIPT_DIR/heighliner.pub"
WG_PROTON_EXPECTED_PUBLIC="$SCRIPT_DIR/proton-client.pub"

WG_PVP_CONF="/etc/wireguard/wg-pvp.conf"
WG_PROTON_CONF="/etc/wireguard/wg-proton.conf"
WG_PVP_ADDRESS="10.9.0.1/24"
WG_PVP_PORT="51821"

# Restrictive-network fallback:
# Caddy remains the public TLS endpoint on TCP/443.
# wstunnel listens only on the Docker host-gateway address using plain WebSocket;
# Caddy proxies vpn.wormlogic.com to this listener.
WSTUNNEL_VERSION="${WSTUNNEL_VERSION:-10.6.2}"
WSTUNNEL_BIN="/usr/local/bin/wstunnel"
WSTUNNEL_PORT="${WSTUNNEL_PORT:-51823}"
WSTUNNEL_SERVICE="/etc/systemd/system/wormlogic-pvp-wstunnel.service"

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

private_key_from_config() {
  local config_file="$1"

  awk '
    /^[[:space:]]*PrivateKey[[:space:]]*=/ {
      pos=index($0, "=")
      value=substr($0, pos + 1)
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      print value
      exit
    }
  ' "$config_file"
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
  local recovered_config="$1"
  local output_file="$2"
  local private_key
  local -a peer_files=()

  private_key="$(private_key_from_config "$recovered_config")"

  if [[ -z "$private_key" ]]; then
    echo "✗ Recovered wg-pvp config has no PrivateKey: $recovered_config"
    exit 1
  fi

  shopt -s nullglob
  peer_files=("$PEER_DIR"/*.conf)
  shopt -u nullglob

  if ((${#peer_files[@]} == 0)); then
    echo "✗ No committed wg-pvp peer definitions found in $PEER_DIR"
    echo "  Credential recovery must complete before PVP setup."
    exit 1
  fi

  {
    echo "[Interface]"
    printf 'PrivateKey = %s\n' "$private_key"
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

ensure_wstunnel() {
  local machine asset checksum installed_version archive extract_dir

  machine="$(uname -m)"

  case "$machine" in
    x86_64)
      asset="wstunnel_${WSTUNNEL_VERSION}_linux_amd64.tar.gz"
      checksum="db6064cca0515b67f8652e201cff8e27553b8cbb7216b2e19241311e34868e6e"
      ;;
    aarch64|arm64)
      asset="wstunnel_${WSTUNNEL_VERSION}_linux_arm64.tar.gz"
      checksum="26bb36b856948255bec7cd71a39df5f8912acdd7a47a9ccd4044a9b80ced108d"
      ;;
    *)
      echo "✗ Unsupported architecture for wstunnel: $machine"
      exit 1
      ;;
  esac

  if [[ -x "$WSTUNNEL_BIN" ]]; then
    installed_version="$("$WSTUNNEL_BIN" --version 2>/dev/null || true)"
    if [[ "$installed_version" == *"$WSTUNNEL_VERSION"* ]]; then
      echo "✓ wstunnel $WSTUNNEL_VERSION already installed"
      return 0
    fi
  fi

  echo "📦 Installing wstunnel $WSTUNNEL_VERSION..."

  archive="$TMP_DIR/$asset"
  extract_dir="$TMP_DIR/wstunnel-extract"
  mkdir -p "$extract_dir"

  curl -fsSL \
    "https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VERSION}/${asset}" \
    -o "$archive"

  printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c -

  tar -xzf "$archive" -C "$extract_dir"

  if [[ ! -f "$extract_dir/wstunnel" ]]; then
    echo "✗ wstunnel archive did not contain the expected binary"
    exit 1
  fi

  sudo install -m 0755 "$extract_dir/wstunnel" "$WSTUNNEL_BIN"

  if ! "$WSTUNNEL_BIN" --version 2>/dev/null | grep -Fq "$WSTUNNEL_VERSION"; then
    echo "✗ Installed wstunnel version did not validate"
    exit 1
  fi

  echo "✓ wstunnel $WSTUNNEL_VERSION installed"
}

docker_host_gateway_ip() {
  local gateway=""

  gateway="$(
    ip -4 -o addr show dev docker0 2>/dev/null |
      awk '{split($4, a, "/"); print a[1]; exit}'
  )"

  if [[ -z "$gateway" ]]; then
    echo "✗ Could not determine Docker host-gateway address from docker0" >&2
    echo "  Docker must be running before PVP fallback setup." >&2
    return 1
  fi

  printf '%s\n' "$gateway"
}

install_wstunnel_service() {
  local gateway_ip="$1"

  echo "🌐 Installing PVP WebSocket fallback service..."

  sudo tee "$WSTUNNEL_SERVICE" >/dev/null <<EOF
[Unit]
Description=Wormlogic PVP WebSocket transport
After=network-online.target wg-quick@wg-pvp.service
Wants=network-online.target
Requires=wg-quick@wg-pvp.service

[Service]
Type=simple
ExecStart=$WSTUNNEL_BIN server --log-lvl WARN --restrict-to 127.0.0.1:$WG_PVP_PORT ws://$gateway_ip:$WSTUNNEL_PORT
Restart=on-failure
RestartSec=2s

NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF

  sudo chmod 0644 "$WSTUNNEL_SERVICE"
  sudo systemctl daemon-reload

  echo "✓ PVP WebSocket fallback service installed"
  echo "  Listener: ws://$gateway_ip:$WSTUNNEL_PORT"
  echo "  Target:   127.0.0.1:$WG_PVP_PORT"
}

start_wstunnel_service() {
  sudo systemctl enable --now wormlogic-pvp-wstunnel.service

  if ! systemctl is-active --quiet wormlogic-pvp-wstunnel.service; then
    echo "✗ wormlogic-pvp-wstunnel.service failed to start"
    sudo systemctl --no-pager --full status wormlogic-pvp-wstunnel.service || true
    exit 1
  fi
}

install_files() {
  local pvp_config_temp="$1"
  local proton_config_temp="$2"
  local pvp_public_source="$3"
  local proton_public_source="$4"

  sudo install -d -m 0700 /etc/wireguard
  sudo install -d -m 0755 /etc/nftables.d
  sudo install -d -m 0755 /usr/local/lib/wormlogic
  sudo install -d -m 0755 /etc/iproute2/rt_tables.d

  sudo install -m 0600 "$pvp_config_temp" "$WG_PVP_CONF"
  sudo install -m 0600 "$proton_config_temp" "$WG_PROTON_CONF"
  sudo install -m 0644 "$pvp_public_source" /etc/wireguard/wg-pvp.public
  sudo install -m 0644 "$proton_public_source" /etc/wireguard/wg-proton.public

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

  for command_name in wg wg-quick ip nft sysctl systemctl awk curl sha256sum tar grep; do
    require_command "$command_name"
  done

  require_file "$WG_PVP_RECOVERED_CONF" "recovered wg-pvp config"
  require_file "$WG_PVP_RECOVERED_PUBLIC" "recovered wg-pvp public key"
  require_file "$WG_PROTON_RECOVERED_CONF" "recovered Proton WireGuard config"
  require_file "$WG_PROTON_RECOVERED_PUBLIC" "recovered Proton client public key"
  require_file "$WG_PVP_EXPECTED_PUBLIC" "expected wg-pvp public identity"
  require_file "$WG_PROTON_EXPECTED_PUBLIC" "expected Proton client public identity"
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

  local pvp_recovered_public proton_recovered_public
  local pvp_expected proton_expected

  pvp_recovered_public="$(tr -d '\r\n' < "$WG_PVP_RECOVERED_PUBLIC")"
  proton_recovered_public="$(tr -d '\r\n' < "$WG_PROTON_RECOVERED_PUBLIC")"
  pvp_expected="$(tr -d '\r\n' < "$WG_PVP_EXPECTED_PUBLIC")"
  proton_expected="$(tr -d '\r\n' < "$WG_PROTON_EXPECTED_PUBLIC")"

  if [[ "$pvp_recovered_public" != "$pvp_expected" ]]; then
    echo "✗ Recovered wg-pvp public key does not match Heighliner's expected identity"
    echo "  Expected public key:  $pvp_expected"
    echo "  Recovered public key: $pvp_recovered_public"
    exit 1
  fi

  if [[ "$proton_recovered_public" != "$proton_expected" ]]; then
    echo "✗ Recovered Proton public key does not match the expected client identity"
    echo "  Expected public key:  $proton_expected"
    echo "  Recovered public key: $proton_recovered_public"
    exit 1
  fi

  TMP_DIR="$(mktemp -d)"
  chmod 700 "$TMP_DIR"

  local docker_gateway_ip
  docker_gateway_ip="$(docker_host_gateway_ip)"

  ensure_wstunnel
  install_wstunnel_service "$docker_gateway_ip"

  local pvp_conf_temp="$TMP_DIR/wg-pvp.conf"
  local pvp_stripped_temp="$TMP_DIR/wg-pvp.stripped"
  local proton_conf_temp="$TMP_DIR/wg-proton.conf"
  local proton_stripped_temp="$TMP_DIR/wg-proton.stripped"

  build_wg_pvp_config "$WG_PVP_RECOVERED_CONF" "$pvp_conf_temp"

  install -m 0600 "$WG_PROTON_RECOVERED_CONF" "$proton_conf_temp"
  validate_proton_config "$proton_conf_temp"

  wg-quick strip "$pvp_conf_temp" > "$pvp_stripped_temp"
  wg-quick strip "$proton_conf_temp" > "$proton_stripped_temp"
  chmod 600 "$pvp_stripped_temp" "$proton_stripped_temp"

  install_files \
    "$pvp_conf_temp" \
    "$proton_conf_temp" \
    "$WG_PVP_RECOVERED_PUBLIC" \
    "$WG_PROTON_RECOVERED_PUBLIC"

  sync_or_start_interface "wg-pvp" "$pvp_conf_temp" "$WG_PVP_ADDRESS" "$pvp_stripped_temp"
  sync_or_start_interface "wg-proton" "$proton_conf_temp" "" "$proton_stripped_temp"

  if [[ "$(sudo wg show wg-pvp public-key)" != "$pvp_expected" ]]; then
    echo "✗ wg-pvp started with an unexpected public key"
    exit 1
  fi

  if [[ "$(sudo wg show wg-proton public-key)" != "$proton_expected" ]]; then
    echo "✗ wg-proton started with an unexpected public key"
    exit 1
  fi

  start_wstunnel_service

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
  echo "  native transport: UDP/$WG_PVP_PORT"
  echo "  fallback listener: ws://$(docker_host_gateway_ip):$WSTUNNEL_PORT"
  echo "  public WSS endpoint: Caddy-owned TCP/443 for vpn.wormlogic.com"
  echo "  external requirement: provider firewall permits UDP/$WG_PVP_PORT and TCP/443"
}

main "$@"
