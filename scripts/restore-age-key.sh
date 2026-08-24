#!/usr/bin/env bash
set -euo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACHINE_ID_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id"
AGE_BASE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sops"
AGE_DIR="$AGE_BASE_DIR/age"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$AGE_DIR/keys.txt}"
AGE_KEY_DIR="$(dirname "$AGE_KEY_FILE")"
DOTFILES_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles"
PUBLIC_KEY_FILE="$DOTFILES_DIR/age-public-key"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" && -e "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

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

RECOVERY_FILE="$REPO_ROOT/secrets/$MACHINE_ID/age-key.age"

mkdir -p "$AGE_KEY_DIR" "$DOTFILES_DIR"
if [[ "$AGE_KEY_FILE" == "$AGE_BASE_DIR"/* ]]; then
  mkdir -p "$AGE_BASE_DIR"
  chmod 700 "$AGE_BASE_DIR"
fi
chmod 700 "$AGE_KEY_DIR"

if [[ -f "$AGE_KEY_FILE" ]]; then
  PUBLIC_KEY="$(age-keygen -y "$AGE_KEY_FILE" 2>/dev/null || true)"
  [[ "$PUBLIC_KEY" =~ ^age1 ]] || {
    echo "✗ Existing age identity is invalid: $AGE_KEY_FILE"
    exit 1
  }

  printf '%s\n' "$PUBLIC_KEY" > "$PUBLIC_KEY_FILE"
  chmod 644 "$PUBLIC_KEY_FILE"

  echo "✓ Existing age identity is valid; recovery not needed"
  echo "  Machine:    $MACHINE_ID"
  echo "  Public key: $PUBLIC_KEY"
  exit 0
fi

[[ -f "$RECOVERY_FILE" ]] || {
  echo "✗ No age recovery copy exists for $MACHINE_ID"
  echo "  Expected: $RECOVERY_FILE"
  exit 1
}

TMP_FILE="$AGE_KEY_DIR/.keys.txt.restore.$$"

cat <<EOF_NOTICE
🔐 Restoring SOPS age identity for: $MACHINE_ID
  Source: $RECOVERY_FILE
  Target: $AGE_KEY_FILE

Enter the independent recovery passphrase when prompted.
EOF_NOTICE

age --decrypt --output "$TMP_FILE" "$RECOVERY_FILE"
chmod 600 "$TMP_FILE"

PUBLIC_KEY="$(age-keygen -y "$TMP_FILE" 2>/dev/null || true)"
[[ "$PUBLIC_KEY" =~ ^age1 ]] || {
  echo "✗ Decrypted recovery material is not a valid age identity"
  exit 1
}

mv "$TMP_FILE" "$AGE_KEY_FILE"
TMP_FILE=""
chmod 600 "$AGE_KEY_FILE"

printf '%s\n' "$PUBLIC_KEY" > "$PUBLIC_KEY_FILE"
chmod 644 "$PUBLIC_KEY_FILE"

cat <<EOF_DONE

✓ SOPS age identity restored
  Machine:    $MACHINE_ID
  Public key: $PUBLIC_KEY
  Identity:   $AGE_KEY_FILE
EOF_DONE
