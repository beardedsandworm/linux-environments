#!/usr/bin/env bash
set -euo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACHINE_ID_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt}"

FORCE=0
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" && -e "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: capture-age-key.sh [--force]

Creates a passphrase-encrypted recovery copy of this machine's SOPS age
identity at:

  secrets/<machine-id>/age-key.age

The machine ID is read from ~/.config/dotfiles/machine-id.
The recovery passphrase must be stored outside this repository.

Options:
  --force     Intentionally replace an existing recovery blob.
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
  echo "✗ Run this script as the normal user, not as root."
  exit 1
fi

for command_name in age age-keygen; do
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
if [[ -z "$MACHINE_ID" || ! "$MACHINE_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "✗ Invalid machine identity in $MACHINE_ID_FILE"
  exit 1
fi

[[ -f "$AGE_KEY_FILE" ]] || {
  echo "✗ Missing SOPS age identity: $AGE_KEY_FILE"
  exit 1
}

PUBLIC_KEY="$(age-keygen -y "$AGE_KEY_FILE" 2>/dev/null || true)"
[[ "$PUBLIC_KEY" =~ ^age1 ]] || {
  echo "✗ $AGE_KEY_FILE is not a valid age identity file"
  exit 1
}

SECRET_DIR="$REPO_ROOT/secrets/$MACHINE_ID"
OUTPUT_FILE="$SECRET_DIR/age-key.age"
mkdir -p "$SECRET_DIR"
chmod 700 "$SECRET_DIR"

if [[ -e "$OUTPUT_FILE" && $FORCE -ne 1 ]]; then
  echo "✗ Recovery copy already exists: $OUTPUT_FILE"
  echo "  Use --force only when intentionally refreshing it."
  exit 1
fi

TMP_FILE="$SECRET_DIR/.age-key.age.tmp.$$"

cat <<EOF_NOTICE
🔐 Capturing age recovery identity for: $MACHINE_ID

Destination:
  $OUTPUT_FILE

Choose an independent high-entropy recovery passphrase and store it outside
this repository (for example, in your password manager).
EOF_NOTICE

age --armor --passphrase --output "$TMP_FILE" "$AGE_KEY_FILE"
chmod 600 "$TMP_FILE"

# Verify the ciphertext can be opened before replacing an existing recovery
# blob. This prompts for the passphrase a second time by design.
VERIFY_FILE="$SECRET_DIR/.age-key.verify.$$"
trap 'rm -f "$TMP_FILE" "$VERIFY_FILE" 2>/dev/null || true' EXIT
age --decrypt --output "$VERIFY_FILE" "$TMP_FILE"
VERIFY_PUBLIC="$(age-keygen -y "$VERIFY_FILE" 2>/dev/null || true)"
rm -f "$VERIFY_FILE"

if [[ "$VERIFY_PUBLIC" != "$PUBLIC_KEY" ]]; then
  echo "✗ Recovery verification produced a different age identity"
  exit 1
fi

mv -f "$TMP_FILE" "$OUTPUT_FILE"
TMP_FILE=""
chmod 600 "$OUTPUT_FILE"
trap - EXIT

cat <<EOF_DONE

✓ Age recovery identity captured and verified
  Machine:    $MACHINE_ID
  Public key: $PUBLIC_KEY
  Recovery:   $OUTPUT_FILE
EOF_DONE
