#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
PEER_DIR="$REPO_ROOT/system/vps01/ubuntu/wireguard/peers"
TEMP_FILE=""

cleanup() {
  if [[ -n "${TEMP_FILE:-}" ]]; then
    rm -f -- "$TEMP_FILE"
    TEMP_FILE=""
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

usage() {
  echo "Usage: $0 <machine-id> <wireguard-public-key> <vpn-ip/32> [additional-allowed-ip/32]" >&2
}

validate_public_key() {
  local public_key="$1"
  local canonical_key decoded_size

  [[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
  if ! canonical_key="$(
    set -o pipefail
    printf '%s' "$public_key" |
      base64 --decode 2>/dev/null |
      base64 --wrap=0
  )"; then
    return 1
  fi
  [[ "$canonical_key" == "$public_key" ]] || return 1

  if ! decoded_size="$(
    set -o pipefail
    printf '%s' "$public_key" |
      base64 --decode 2>/dev/null |
      wc -c
  )"; then
    return 1
  fi
  [[ "$decoded_size" == "32" ]]
}

main() {
  if (($# < 3 || $# > 4)); then
    usage
    exit 64
  fi

  local machine_id="$1"
  local public_key="$2"
  local vpn_ip="$3"
  local extra_allowed_ip="${4:-}"
  local filename label expected_ip target
  local expected_extra_allowed_ip=""
  local allowed_ips

  case "$machine_id" in
    server01)
      filename="20-arrakis.conf"
      label="Arrakis"
      expected_ip="10.8.0.3/32"
      expected_extra_allowed_ip="10.42.20.4/32"
      ;;
    server02)
      filename="30-ix.conf"
      label="IX"
      expected_ip="10.8.0.4/32"
      ;;
    laptop01)
      filename="40-laptop01.conf"
      label="laptop01"
      expected_ip="10.8.0.10/32"
      ;;
    laptop02)
      filename="50-laptop02.conf"
      label="laptop02"
      expected_ip="10.8.0.11/32"
      ;;
    vps02)
      filename="70-farcaster.conf"
      label="Farcaster / vps02"
      expected_ip="10.8.0.6/32"
      ;;
    server03)
      filename="80-caladan.conf"
      label="Caladan"
      expected_ip="10.8.0.5/32"
      ;;
    server04)
      filename="90-chapterhouse.conf"
      label="Chapterhouse"
      expected_ip="10.8.0.7/32"
      ;;
    *)
      echo "ERROR: unsupported Wormlogic peer machine ID: $machine_id" >&2
      exit 65
      ;;
  esac

  validate_public_key "$public_key" || {
    echo "ERROR: invalid WireGuard public key for $machine_id" >&2
    exit 65
  }

  if [[ "$vpn_ip" != "$expected_ip" ]]; then
    echo "ERROR: unexpected Wormlogic address for $machine_id" >&2
    echo "  expected: $expected_ip" >&2
    echo "  received: $vpn_ip" >&2
    exit 65
  fi

  if [[ "$extra_allowed_ip" != "$expected_extra_allowed_ip" ]]; then
    echo "ERROR: unexpected additional AllowedIPs address for $machine_id" >&2
    echo "  expected: ${expected_extra_allowed_ip:-<none>}" >&2
    echo "  received: ${extra_allowed_ip:-<none>}" >&2
    exit 65
  fi

  allowed_ips="$vpn_ip"
  if [[ -n "$extra_allowed_ip" ]]; then
    allowed_ips+=", $extra_allowed_ip"
  fi

  mkdir -p -- "$PEER_DIR"
  target="$PEER_DIR/$filename"
  TEMP_FILE="$(mktemp "$PEER_DIR/.${filename}.tmp.XXXXXX")"

  {
    echo "[Peer]"
    echo "# $label"
    echo "PublicKey = $public_key"
    echo "AllowedIPs = $allowed_ips"
  } > "$TEMP_FILE"

  chmod 0644 "$TEMP_FILE"
  mv -f -- "$TEMP_FILE" "$target"
  TEMP_FILE=""

  echo "✓ Heighliner peer fragment updated: $target" >&2
}

main "$@"
