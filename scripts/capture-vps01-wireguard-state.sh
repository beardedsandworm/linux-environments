#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_VERSION="2026-08-24.5"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACHINE_ID_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt}"
AGE_PUBLIC_KEY_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/age-public-key"

WG0_CONF="/etc/wireguard/wg0.conf"
WG_PVP_CONF="/etc/wireguard/wg-pvp.conf"
WG_PROTON_CONF="/etc/wireguard/wg-proton.conf"

SECRET_DIR="$REPO_ROOT/secrets/vps01"
PVP_DIR="$REPO_ROOT/system/vps01/ubuntu/pvp"
WG0_DIR="$REPO_ROOT/system/vps01/ubuntu/wireguard"

FORCE=0
TMP_FILES=()

cleanup() {
  local file
  for file in "${TMP_FILES[@]:-}"; do
    [[ -n "$file" ]] && rm -f "$file" 2>/dev/null || true
  done
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: capture-vps01-wireguard-state-v5.sh [--force]

Captures the existing Heighliner identities needed for disaster recovery:
  secrets/vps01/wg0.key.enc
  secrets/vps01/wg-pvp.key.enc
  secrets/vps01/wg-proton.conf.enc

It also records safe public/declarative state:
  system/vps01/ubuntu/wireguard/heighliner.pub
  system/vps01/ubuntu/pvp/heighliner.pub
  system/vps01/ubuntu/pvp/proton-client.pub
  system/vps01/ubuntu/pvp/peers/current.conf

Version 5 deliberately does NOT use `wg pubkey` while capturing identities.
It reads each running interface identity directly and compares the running
private key with PrivateKey= in the persistent configuration without printing it.

Dynamic Endpoint= lines are omitted from wg-pvp peer definitions.
The script refuses to export wg-pvp peers if a PresharedKey= is present.

Options:
  --force     Intentionally replace already captured secret/peer state.
  -h, --help  Show this help.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "✗ Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

echo "capture-vps01-wireguard-state-v5.sh $SCRIPT_VERSION"

if [[ $EUID -eq 0 ]]; then
  echo "✗ Run this script as the normal user, not root."
  exit 1
fi

for command_name in age-keygen sops wg awk grep; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "✗ Required command not found: $command_name"
    exit 1
  }
done

[[ -f "$MACHINE_ID_FILE" ]] || {
  echo "✗ Missing machine identity: $MACHINE_ID_FILE"
  exit 1
}

MACHINE_ID="$(tr -d '\r\n' < "$MACHINE_ID_FILE")"
if [[ "$MACHINE_ID" != "vps01" ]]; then
  echo "✗ This capture helper is specific to vps01; machine-id is '$MACHINE_ID'"
  exit 1
fi

for conf in "$WG0_CONF" "$WG_PVP_CONF" "$WG_PROTON_CONF"; do
  sudo test -f "$conf" || {
    echo "✗ Missing live WireGuard configuration: $conf"
    exit 1
  }
done

if [[ -f "$AGE_PUBLIC_KEY_FILE" ]]; then
  AGE_RECIPIENT="$(tr -d '\r\n' < "$AGE_PUBLIC_KEY_FILE")"
elif [[ -f "$AGE_KEY_FILE" ]]; then
  AGE_RECIPIENT="$(age-keygen -y "$AGE_KEY_FILE")"
else
  echo "✗ Cannot determine this machine's SOPS age recipient"
  exit 1
fi

[[ "$AGE_RECIPIENT" =~ ^age1 ]] || {
  echo "✗ Invalid SOPS age recipient"
  exit 1
}

mkdir -p "$SECRET_DIR" "$PVP_DIR/peers" "$WG0_DIR"
chmod 700 "$SECRET_DIR"

SECRET_OUTPUTS=(
  "$SECRET_DIR/wg0.key.enc"
  "$SECRET_DIR/wg-pvp.key.enc"
  "$SECRET_DIR/wg-proton.conf.enc"
)
PVP_PEER_OUTPUT="$PVP_DIR/peers/current.conf"

if [[ $FORCE -ne 1 ]]; then
  for output in "${SECRET_OUTPUTS[@]}" "$PVP_PEER_OUTPUT"; do
    if [[ -e "$output" ]]; then
      echo "✗ Captured state already exists: $output"
      echo "  Use --force only when intentionally refreshing it."
      exit 1
    fi
  done
fi

if sudo grep -Eq '^[[:space:]]*PresharedKey[[:space:]]*=' "$WG_PVP_CONF"; then
  echo "✗ wg-pvp contains a PresharedKey=."
  echo "  Refusing to export that peer secret into plaintext Git-managed config."
  exit 1
fi

extract_config_private_key() {
  local config="$1"

  sudo awk '
    /^[[:space:]]*PrivateKey[[:space:]]*=/ {
      line = $0
      sub(/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      print line
      exit
    }
  ' "$config"
}

read_running_private_key() {
  local interface="$1"
  local key

  if ! key="$(sudo wg show "$interface" private-key 2>/dev/null)"; then
    echo "✗ Running WireGuard interface '$interface' was not found" >&2
    return 1
  fi

  key="${key//$'\r'/}"
  key="${key//$'\n'/}"

  if [[ -z "$key" || "$key" == "(none)" ]]; then
    echo "✗ Running WireGuard interface '$interface' has no private key" >&2
    return 1
  fi

  printf '%s\n' "$key"
}

verify_identity() {
  local name="$1"
  local interface="$2"
  local config="$3"
  local configured_private running_private running_public

  echo "  • Checking $name ..." >&2

  configured_private="$(extract_config_private_key "$config")"
  if [[ -z "$configured_private" ]]; then
    echo "✗ $name: no PrivateKey= found in $config" >&2
    return 1
  fi

  running_private="$(read_running_private_key "$interface")" || return 1

  if [[ "$configured_private" != "$running_private" ]]; then
    echo "✗ $name: PrivateKey in $config does not match running '$interface'" >&2
    echo "  Refusing to capture ambiguous recovery state." >&2
    return 1
  fi

  if ! running_public="$(sudo wg show "$interface" public-key 2>/dev/null)"; then
    echo "✗ $name: could not read public key from running '$interface'" >&2
    return 1
  fi

  if [[ -z "$running_public" || "$running_public" == "(none)" ]]; then
    echo "✗ $name: running '$interface' has no public key" >&2
    return 1
  fi

  echo "  ✓ $name persistent and running identities match" >&2
  printf '%s\n' "$running_public"
}

echo "🔐 Verifying persistent WireGuard identities without wg pubkey..."
WG0_PUBLIC="$(verify_identity "Wormlogic wg0" "wg0" "$WG0_CONF")"
PVP_PUBLIC="$(verify_identity "PVP wg-pvp" "wg-pvp" "$WG_PVP_CONF")"
PROTON_PUBLIC="$(verify_identity "Proton wg-proton" "wg-proton" "$WG_PROTON_CONF")"
echo "✓ All persistent WireGuard identities verified"

if [[ -f "$WG0_DIR/heighliner.pub" ]]; then
  EXPECTED_WG0_PUBLIC="$(tr -d '\r\n' < "$WG0_DIR/heighliner.pub")"
  if [[ "$EXPECTED_WG0_PUBLIC" != "$WG0_PUBLIC" ]]; then
    echo "✗ Live wg0 public key does not match $WG0_DIR/heighliner.pub"
    echo "  Repo: $EXPECTED_WG0_PUBLIC"
    echo "  Live: $WG0_PUBLIC"
    exit 1
  fi
fi

capture_encrypted_stream() {
  local output="$1"
  shift

  local tmp="${output}.tmp.$$"
  TMP_FILES+=("$tmp")

  "$@" | sops --encrypt \
    --age "$AGE_RECIPIENT" \
    --input-type binary \
    --output-type json \
    /dev/stdin > "$tmp"

  chmod 600 "$tmp"

  sops --decrypt \
    --input-type json \
    --output-type binary \
    "$tmp" >/dev/null

  mv -f "$tmp" "$output"
  chmod 600 "$output"
}

capture_running_private_key() {
  local interface="$1"
  read_running_private_key "$interface"
}

capture_encrypted_stream "$SECRET_DIR/wg0.key.enc" capture_running_private_key "wg0"
capture_encrypted_stream "$SECRET_DIR/wg-pvp.key.enc" capture_running_private_key "wg-pvp"
capture_encrypted_stream "$SECRET_DIR/wg-proton.conf.enc" sudo cat "$WG_PROTON_CONF"

printf '%s\n' "$WG0_PUBLIC" > "$WG0_DIR/heighliner.pub"
printf '%s\n' "$PVP_PUBLIC" > "$PVP_DIR/heighliner.pub"
printf '%s\n' "$PROTON_PUBLIC" > "$PVP_DIR/proton-client.pub"
chmod 644 "$WG0_DIR/heighliner.pub" "$PVP_DIR/heighliner.pub" "$PVP_DIR/proton-client.pub"

PVP_PEERS_TEMP="$PVP_DIR/peers/.current.conf.tmp.$$"
TMP_FILES+=("$PVP_PEERS_TEMP")

sudo awk '
  /^[[:space:]]*\[Peer\][[:space:]]*$/ {
    if (seen_peer) print ""
    seen_peer=1
    in_peer=1
    print "[Peer]"
    next
  }
  /^[[:space:]]*\[Interface\][[:space:]]*$/ {
    in_peer=0
    next
  }
  in_peer {
    if ($0 ~ /^[[:space:]]*Endpoint[[:space:]]*=/) next
    print
  }
' "$WG_PVP_CONF" > "$PVP_PEERS_TEMP"

if [[ ! -s "$PVP_PEERS_TEMP" ]]; then
  echo "✗ No [Peer] sections were found in $WG_PVP_CONF"
  exit 1
fi

mv -f "$PVP_PEERS_TEMP" "$PVP_PEER_OUTPUT"
chmod 644 "$PVP_PEER_OUTPUT"

cat <<EOF_DONE
✓ Captured Heighliner WireGuard recovery state

Encrypted secrets:
  $SECRET_DIR/wg0.key.enc
  $SECRET_DIR/wg-pvp.key.enc
  $SECRET_DIR/wg-proton.conf.enc

Public/declarative state:
  $WG0_DIR/heighliner.pub
  $PVP_DIR/heighliner.pub
  $PVP_DIR/proton-client.pub
  $PVP_PEER_OUTPUT

All three persistent identities matched their running interfaces.
Review 'git diff' before committing.
EOF_DONE
