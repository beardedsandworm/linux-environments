#!/usr/bin/env bash
set -euo pipefail
umask 077

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
Usage: capture-vps01-wireguard-state.sh [--force]

Captures the existing Heighliner identities needed for disaster recovery:
  secrets/vps01/wg0.key.enc
  secrets/vps01/wg-pvp.key.enc
  secrets/vps01/wg-proton.conf.enc

It also records safe public/declarative state:
  system/vps01/ubuntu/wireguard/heighliner.pub
  system/vps01/ubuntu/pvp/heighliner.pub
  system/vps01/ubuntu/pvp/proton-client.pub
  system/vps01/ubuntu/pvp/peers/current.conf

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
  echo "✗ Invalid SOPS age recipient: $AGE_RECIPIENT"
  exit 1
}

mkdir -p "$SECRET_DIR" "$PVP_DIR/peers"
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

extract_private_key() {
  local config="$1"
  sudo awk -F '[[:space:]]*=[[:space:]]*' \
    '/^[[:space:]]*PrivateKey[[:space:]]*=/ {print $2; exit}' "$config"
}

# Resolve and verify all three persistent identities before writing anything to
# the repository. This catches persistent/runtime drift rather than capturing an
# ambiguous recovery state.
WG0_PUBLIC="$(extract_private_key "$WG0_CONF" | wg pubkey)"
PVP_PUBLIC="$(extract_private_key "$WG_PVP_CONF" | wg pubkey)"
PROTON_PUBLIC="$(extract_private_key "$WG_PROTON_CONF" | wg pubkey)"

RUNNING_WG0_PUBLIC="$(sudo wg show wg0 public-key)"
RUNNING_PVP_PUBLIC="$(sudo wg show wg-pvp public-key)"
RUNNING_PROTON_PUBLIC="$(sudo wg show wg-proton public-key)"

if [[ "$WG0_PUBLIC" != "$RUNNING_WG0_PUBLIC" || \
      "$PVP_PUBLIC" != "$RUNNING_PVP_PUBLIC" || \
      "$PROTON_PUBLIC" != "$RUNNING_PROTON_PUBLIC" ]]; then
  echo "✗ Persistent WireGuard identity does not match a running interface"
  echo "  Refusing to capture ambiguous recovery state."
  exit 1
fi

# The known wg0 public identity is already committed in this proposal. Treat a
# mismatch as a serious error rather than silently replacing it.
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

capture_encrypted_stream "$SECRET_DIR/wg0.key.enc" extract_private_key "$WG0_CONF"
capture_encrypted_stream "$SECRET_DIR/wg-pvp.key.enc" extract_private_key "$WG_PVP_CONF"
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
