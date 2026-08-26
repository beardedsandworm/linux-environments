#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Capture complete WireGuard configuration files for this machine and encrypt
# each file once with SOPS using the machine's existing age identity.
#
# Repository layout:
#   secrets/<machine-id>/wireguard/<interface>.conf.enc
#
# The encrypted config is the recovery artifact. It already contains the
# interface private key, any preshared keys, addresses, peers, endpoints,
# AllowedIPs, wg-quick settings, and provider-specific options present in the
# source file. This script intentionally does not extract or separately encrypt
# those credentials.
#
# This script does not generate WireGuard configurations or keys.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

REPO_ROOT="${REPO_ROOT:-$DEFAULT_REPO_ROOT}"
MACHINE_ID_FILE="${MACHINE_ID_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id}"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt}"
WIREGUARD_CONFIG_DIR="${WIREGUARD_CONFIG_DIR:-/etc/wireguard}"

MACHINE_ID_OVERRIDE=""
FORCE=0

usage() {
  cat <<'EOF'
Usage: capture-wireguard-credentials.sh [options]

Options:
  --repo-root PATH       Dotfiles repository root.
  --machine-id ID        Override machine ID instead of reading machine-id file.
  --age-key PATH         SOPS age identity file.
  --wg-config-dir PATH   WireGuard config directory (default: /etc/wireguard).
  --force                Replace a different existing encrypted config.
  -h, --help             Show this help.

Environment equivalents:
  REPO_ROOT
  MACHINE_ID_FILE
  SOPS_AGE_KEY_FILE
  WIREGUARD_CONFIG_DIR
EOF
}

while (($#)); do
  case "$1" in
    --repo-root)
      [[ $# -ge 2 ]] || { echo "ERROR: --repo-root requires a value" >&2; exit 2; }
      REPO_ROOT="$2"
      shift 2
      ;;
    --machine-id)
      [[ $# -ge 2 ]] || { echo "ERROR: --machine-id requires a value" >&2; exit 2; }
      MACHINE_ID_OVERRIDE="$2"
      shift 2
      ;;
    --age-key)
      [[ $# -ge 2 ]] || { echo "ERROR: --age-key requires a value" >&2; exit 2; }
      AGE_KEY_FILE="$2"
      shift 2
      ;;
    --wg-config-dir)
      [[ $# -ge 2 ]] || { echo "ERROR: --wg-config-dir requires a value" >&2; exit 2; }
      WIREGUARD_CONFIG_DIR="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

need_cmd sops
need_cmd age-keygen
need_cmd sha256sum
need_cmd awk
need_cmd find
need_cmd mktemp

if [[ -n "$MACHINE_ID_OVERRIDE" ]]; then
  MACHINE_ID="$MACHINE_ID_OVERRIDE"
else
  [[ -r "$MACHINE_ID_FILE" ]] || {
    echo "ERROR: machine ID file not readable: $MACHINE_ID_FILE" >&2
    exit 1
  }
  MACHINE_ID="$(tr -d '[:space:]' < "$MACHINE_ID_FILE")"
fi

[[ "$MACHINE_ID" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "ERROR: invalid machine ID: $MACHINE_ID" >&2
  exit 1
}

[[ -r "$AGE_KEY_FILE" ]] || {
  echo "ERROR: SOPS age identity not readable: $AGE_KEY_FILE" >&2
  echo "Run the age-key generation/restoration step first." >&2
  exit 1
}

AGE_RECIPIENT="$(age-keygen -y "$AGE_KEY_FILE" 2>/dev/null)" || {
  echo "ERROR: could not derive age recipient from: $AGE_KEY_FILE" >&2
  exit 1
}

[[ "$AGE_RECIPIENT" == age1* ]] || {
  echo "ERROR: derived age recipient is not valid." >&2
  exit 1
}

DEST_DIR="$REPO_ROOT/secrets/$MACHINE_ID/wireguard"
mkdir -p "$DEST_DIR"
chmod 700 "$DEST_DIR" 2>/dev/null || true

if (( EUID == 0 )); then
  ROOT=()
else
  command -v sudo >/dev/null 2>&1 || {
    echo "ERROR: sudo is required to read WireGuard configuration files." >&2
    exit 1
  }
  ROOT=(sudo)
fi

if ! "${ROOT[@]}" test -d "$WIREGUARD_CONFIG_DIR"; then
  echo "ERROR: WireGuard config directory does not exist: $WIREGUARD_CONFIG_DIR" >&2
  exit 1
fi

sops_decrypt_hash() {
  local source="$1"

  SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
    sops decrypt \
      --input-type json \
      --output-type binary \
      "$source" |
    sha256sum |
    awk '{print $1}'
}

source_hash() {
  local source="$1"
  "${ROOT[@]}" sha256sum "$source" | awk '{print $1}'
}

encrypt_config_atomic() {
  local source="$1"
  local dest="$2"
  local existing_hash current_hash tmp

  current_hash="$(source_hash "$source")"

  if [[ -e "$dest" ]]; then
    existing_hash="$(sops_decrypt_hash "$dest")" || {
      echo "ERROR: failed to decrypt existing recovery artifact: $dest" >&2
      return 1
    }

    if [[ "$existing_hash" == "$current_hash" ]]; then
      echo "unchanged: $dest"
      return 0
    fi

    if (( FORCE != 1 )); then
      echo "ERROR: encrypted config differs from the live source:" >&2
      echo "  source: $source" >&2
      echo "  repo:   $dest" >&2
      echo "Use --force only when the live config is authoritative." >&2
      return 1
    fi
  fi

  tmp="$(mktemp "${dest}.tmp.XXXXXX")"
  trap 'rm -f -- "$tmp"' RETURN

  "${ROOT[@]}" cat -- "$source" |
    sops encrypt \
      --age "$AGE_RECIPIENT" \
      --input-type binary \
      --output-type json \
      /dev/stdin > "$tmp"

  chmod 600 "$tmp"
  mv -f -- "$tmp" "$dest"
  trap - RETURN

  echo "captured:  $dest"
}

mapfile -t CONFIG_FILES < <(
  "${ROOT[@]}" find "$WIREGUARD_CONFIG_DIR" \
    -maxdepth 1 \
    -type f \
    -name '*.conf' \
    -print 2>/dev/null |
  sort
)

if ((${#CONFIG_FILES[@]} == 0)); then
  echo "ERROR: no WireGuard *.conf files found in $WIREGUARD_CONFIG_DIR." >&2
  echo "This capture workflow backs up complete config files; it does not reconstruct" >&2
  echo "configs from live interfaces." >&2
  exit 1
fi

captured=0

for conf in "${CONFIG_FILES[@]}"; do
  filename="$(basename -- "$conf")"
  iface="${filename%.conf}"

  [[ "$iface" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    echo "ERROR: unsafe WireGuard interface name: $iface" >&2
    exit 1
  }

  encrypt_config_atomic "$conf" "$DEST_DIR/$iface.conf.enc"
  ((captured += 1))
done

shopt -s nullglob
legacy_files=(
  "$DEST_DIR"/*.private-key.enc
  "$DEST_DIR"/*.preshared-keys.enc
  "$DEST_DIR"/*.private-key.age
  "$DEST_DIR"/*.preshared-keys.age
)
shopt -u nullglob

echo
echo "Captured $captured complete WireGuard config file(s) with SOPS/age."
echo "Recovery directory: $DEST_DIR"

if ((${#legacy_files[@]} > 0)); then
  echo
  echo "WARNING: legacy extracted-key recovery artifacts still exist:"
  printf '  %s\n' "${legacy_files[@]}"
  echo "They are not written or used by this capture format."
  echo "Remove them after verifying the new *.conf.enc recovery artifacts."
fi
