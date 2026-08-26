#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Restore this machine's complete SOPS/age-encrypted WireGuard configuration
# files into a predictable local staging directory.
#
# Repository input:
#   secrets/<machine-id>/wireguard/<interface>.conf.enc
#
# Restored output:
#   ~/.config/dotfiles/wireguard/<interface>.conf
#   ~/.config/dotfiles/wireguard/<interface>.public-key
#
# The complete config remains the single plaintext source of private WireGuard
# credential material in the staging directory. The public key is derived from
# the restored config because it is non-secret and useful to setup/validation
# code. No separate <interface>.private-key file is created.
#
# This script does not install /etc/wireguard/*.conf or restart interfaces.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

REPO_ROOT="${REPO_ROOT:-$DEFAULT_REPO_ROOT}"
MACHINE_ID_FILE="${MACHINE_ID_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id}"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt}"
OUTPUT_DIR="${WIREGUARD_CREDENTIAL_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/wireguard}"

MACHINE_ID_OVERRIDE=""
FORCE=0
TEMP_FILES=()

cleanup() {
  local file
  for file in "${TEMP_FILES[@]:-}"; do
    [[ -n "$file" ]] && rm -f -- "$file"
  done
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: restore-wireguard-credentials.sh [options]

Options:
  --repo-root PATH       Dotfiles repository root.
  --machine-id ID        Override machine ID instead of reading machine-id file.
  --age-key PATH         SOPS age identity file.
  --output-dir PATH      Restored WireGuard staging directory.
  --force                Replace a different existing staged config.
  -h, --help             Show this help.

Environment equivalents:
  REPO_ROOT
  MACHINE_ID_FILE
  SOPS_AGE_KEY_FILE
  WIREGUARD_CREDENTIAL_DIR
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
    --output-dir)
      [[ $# -ge 2 ]] || { echo "ERROR: --output-dir requires a value" >&2; exit 2; }
      OUTPUT_DIR="$2"
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
need_cmd wg
need_cmd awk
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

SOURCE_DIR="$REPO_ROOT/secrets/$MACHINE_ID/wireguard"

[[ -d "$SOURCE_DIR" ]] || {
  echo "ERROR: no encrypted WireGuard recovery directory for $MACHINE_ID:" >&2
  echo "  $SOURCE_DIR" >&2
  exit 1
}

shopt -s nullglob
encrypted_configs=("$SOURCE_DIR"/*.conf.enc)
legacy_files=(
  "$SOURCE_DIR"/*.private-key.enc
  "$SOURCE_DIR"/*.preshared-keys.enc
  "$SOURCE_DIR"/*.private-key.age
  "$SOURCE_DIR"/*.preshared-keys.age
)
shopt -u nullglob

if ((${#encrypted_configs[@]} == 0)); then
  echo "ERROR: no SOPS-encrypted WireGuard config files found for $MACHINE_ID." >&2
  echo "Expected: $SOURCE_DIR/<interface>.conf.enc" >&2

  if ((${#legacy_files[@]} > 0)); then
    echo "Legacy extracted-key artifacts are present, but this restore version does" >&2
    echo "not use them. Re-capture the current /etc/wireguard/*.conf files with the" >&2
    echo "updated capture-wireguard-credentials.sh first." >&2
  fi

  exit 1
fi

mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"

sops_decrypt_to_file() {
  local source="$1"
  local target="$2"

  SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
    sops decrypt \
      --input-type json \
      --output-type binary \
      "$source" > "$target"

  chmod 600 "$target"
}

private_key_from_config() {
  local config="$1"

  awk '
    /^[[:space:]]*PrivateKey[[:space:]]*=/ {
      pos=index($0, "=")
      value=substr($0, pos + 1)
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      print value
      exit
    }
  ' "$config" | tr -d '[:space:]'
}

install_config_atomic() {
  local decrypted_temp="$1"
  local dest="$2"

  if [[ -e "$dest" ]]; then
    if cmp -s -- "$decrypted_temp" "$dest"; then
      chmod 600 "$dest"
      echo "unchanged: $dest"
      return 0
    fi

    if (( FORCE != 1 )); then
      echo "ERROR: refusing to replace different existing staged config:" >&2
      echo "  $dest" >&2
      echo "Use --force only when the repository copy is authoritative." >&2
      return 1
    fi
  fi

  mv -f -- "$decrypted_temp" "$dest"
  chmod 600 "$dest"
  echo "restored:  $dest"
}

write_public_key_atomic() {
  local public_key="$1"
  local dest="$2"
  local tmp

  tmp="$(mktemp "${dest}.tmp.XXXXXX")"
  printf '%s\n' "$public_key" > "$tmp"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$dest"
}

restored=0

for encrypted_config in "${encrypted_configs[@]}"; do
  filename="$(basename -- "$encrypted_config")"
  iface="${filename%.conf.enc}"

  [[ "$iface" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    echo "ERROR: unsafe interface name derived from repository: $iface" >&2
    exit 1
  }

  config_dest="$OUTPUT_DIR/$iface.conf"
  public_dest="$OUTPUT_DIR/$iface.public-key"
  config_temp="$(mktemp "$OUTPUT_DIR/.${iface}.conf.tmp.XXXXXX")"
  TEMP_FILES+=("$config_temp")

  sops_decrypt_to_file "$encrypted_config" "$config_temp" || {
    echo "ERROR: failed to decrypt: $encrypted_config" >&2
    exit 1
  }

  private_key="$(private_key_from_config "$config_temp")"
  if [[ -z "$private_key" ]]; then
    echo "ERROR: restored config has no PrivateKey: $encrypted_config" >&2
    exit 1
  fi

  if ! printf '%s\n' "$private_key" | wg pubkey >/dev/null 2>&1; then
    echo "ERROR: restored config contains an invalid WireGuard PrivateKey:" >&2
    echo "  $encrypted_config" >&2
    exit 1
  fi

  public_key="$(printf '%s\n' "$private_key" | wg pubkey)"

  install_config_atomic "$config_temp" "$config_dest"

  # install_config_atomic moves the temp file when restoring. If it reported
  # unchanged, the temp still exists and can now be removed.
  rm -f -- "$config_temp"

  write_public_key_atomic "$public_key" "$public_dest"

  printf '%-20s %s\n' "$iface" "$public_key"
  ((restored += 1))
done

echo
echo "Restored $restored complete WireGuard config file(s) from SOPS/age."
echo "Staging directory: $OUTPUT_DIR"

if ((${#legacy_files[@]} > 0)); then
  echo
  echo "WARNING: legacy extracted-key recovery artifacts still exist:"
  printf '  %s\n' "${legacy_files[@]}"
  echo "They are ignored by this restore format."
fi
