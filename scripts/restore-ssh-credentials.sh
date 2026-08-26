#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Restore this machine's SOPS/age-encrypted SSH private credentials.
#
# Repository input:
#   secrets/<machine-id>/ssh/user/<filename>.enc
#   secrets/<machine-id>/ssh/host/<filename>.enc
#
# Restore targets:
#   user/* -> ~/.ssh/<filename>
#   host/* -> /etc/ssh/<filename>
#
# This script intentionally does not restore authorized_keys, SSH config,
# or known_hosts. Public .pub files are regenerated from restored private keys.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

REPO_ROOT="${REPO_ROOT:-$DEFAULT_REPO_ROOT}"
MACHINE_ID_FILE="${MACHINE_ID_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id}"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt}"
SSH_USER_DIR="${SSH_USER_DIR:-$HOME/.ssh}"
SSH_HOST_DIR="${SSH_HOST_DIR:-/etc/ssh}"

MACHINE_ID_OVERRIDE=""
FORCE=0

usage() {
  cat <<'EOF'
Usage: restore-ssh-credentials.sh [options]

Options:
  --repo-root PATH       Dotfiles repository root.
  --machine-id ID        Override machine ID instead of reading machine-id file.
  --age-key PATH         SOPS age identity file.
  --user-ssh-dir PATH    User SSH directory (default: ~/.ssh).
  --host-ssh-dir PATH    Host SSH directory (default: /etc/ssh).
  --force                Replace different existing private keys.
                         Fresh-machine bootstrap recovery will normally need
                         this for installer-generated OpenSSH host keys.
  -h, --help             Show this help.

Environment equivalents:
  REPO_ROOT
  MACHINE_ID_FILE
  SOPS_AGE_KEY_FILE
  SSH_USER_DIR
  SSH_HOST_DIR
EOF
}

while (($#)); do
  case "$1" in
    --repo-root)
      [[ $# -ge 2 ]] || { echo "ERROR: --repo-root requires a value" >&2; exit 2; }
      REPO_ROOT="$2"; shift 2 ;;
    --machine-id)
      [[ $# -ge 2 ]] || { echo "ERROR: --machine-id requires a value" >&2; exit 2; }
      MACHINE_ID_OVERRIDE="$2"; shift 2 ;;
    --age-key)
      [[ $# -ge 2 ]] || { echo "ERROR: --age-key requires a value" >&2; exit 2; }
      AGE_KEY_FILE="$2"; shift 2 ;;
    --user-ssh-dir)
      [[ $# -ge 2 ]] || { echo "ERROR: --user-ssh-dir requires a value" >&2; exit 2; }
      SSH_USER_DIR="$2"; shift 2 ;;
    --host-ssh-dir)
      [[ $# -ge 2 ]] || { echo "ERROR: --host-ssh-dir requires a value" >&2; exit 2; }
      SSH_HOST_DIR="$2"; shift 2 ;;
    --force)
      FORCE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

need_cmd sops
need_cmd mktemp
need_cmd cmp
need_cmd head
need_cmd install
need_cmd ssh-keygen

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

SOURCE_ROOT="$REPO_ROOT/secrets/$MACHINE_ID/ssh"
USER_SOURCE="$SOURCE_ROOT/user"
HOST_SOURCE="$SOURCE_ROOT/host"

[[ -d "$SOURCE_ROOT" ]] || {
  echo "ERROR: no encrypted SSH credential directory for $MACHINE_ID:" >&2
  echo "  $SOURCE_ROOT" >&2
  exit 1
}

if (( EUID == 0 )); then
  ROOT=()
else
  command -v sudo >/dev/null 2>&1 || {
    echo "ERROR: sudo is required to restore OpenSSH host private keys." >&2
    exit 1
  }
  ROOT=(sudo)
fi

is_private_key_file() {
  local path="$1"
  local first_line

  IFS= read -r first_line < "$path" || true

  case "$first_line" in
    "-----BEGIN OPENSSH PRIVATE KEY-----" | \
    "-----BEGIN RSA PRIVATE KEY-----" | \
    "-----BEGIN DSA PRIVATE KEY-----" | \
    "-----BEGIN EC PRIVATE KEY-----" | \
    "-----BEGIN PRIVATE KEY-----" | \
    "-----BEGIN ENCRYPTED PRIVATE KEY-----" | \
    "---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

decrypt_to_temp() {
  local src="$1"
  local tmp="$2"

  SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
    sops decrypt \
      --input-type json \
      --output-type binary \
      "$src" > "$tmp"
}

restore_user_key() {
  local encrypted="$1"
  local name dest tmp

  name="$(basename -- "$encrypted" .enc)"
  [[ "$name" =~ ^[A-Za-z0-9._@+-]+$ ]] || {
    echo "ERROR: unsafe user SSH key filename: $name" >&2
    return 1
  }

  dest="$SSH_USER_DIR/$name"
  tmp="$(mktemp)"
  trap 'rm -f -- "$tmp"' RETURN

  decrypt_to_temp "$encrypted" "$tmp"

  if ! is_private_key_file "$tmp"; then
    echo "ERROR: decrypted file is not a recognized SSH private key: $encrypted" >&2
    return 1
  fi

  if [[ -e "$dest" ]]; then
    if cmp -s -- "$tmp" "$dest"; then
      chmod 600 "$dest"
      rm -f -- "$tmp"
      trap - RETURN

      pub_tmp="$(mktemp)"
      trap 'rm -f -- "$pub_tmp"' RETURN
      if ! ssh-keygen -y -f "$dest" > "$pub_tmp"; then
        echo "ERROR: failed to derive public key from restored private key: $dest" >&2
        return 1
      fi
      install -m 644 -- "$pub_tmp" "$dest.pub"
      rm -f -- "$pub_tmp"
      trap - RETURN

      echo "unchanged: $dest"
      echo "derived:   $dest.pub"
      return 0
    fi

    if (( FORCE != 1 )); then
      echo "ERROR: refusing to replace different existing private key: $dest" >&2
      echo "Use --force only during intentional recovery/replacement." >&2
      return 1
    fi
  fi

  install -m 600 -- "$tmp" "$dest"
  rm -f -- "$tmp"
  trap - RETURN

  pub_tmp="$(mktemp)"
  trap 'rm -f -- "$pub_tmp"' RETURN
  if ! ssh-keygen -y -f "$dest" > "$pub_tmp"; then
    echo "ERROR: failed to derive public key from restored private key: $dest" >&2
    return 1
  fi
  install -m 644 -- "$pub_tmp" "$dest.pub"
  rm -f -- "$pub_tmp"
  trap - RETURN

  echo "restored:  $dest"
  echo "derived:   $dest.pub"
}

restore_host_key() {
  local encrypted="$1"
  local name dest tmp

  name="$(basename -- "$encrypted" .enc)"
  [[ "$name" =~ ^ssh_host_[A-Za-z0-9_.-]+_key$ ]] || {
    echo "ERROR: unsafe OpenSSH host key filename: $name" >&2
    return 1
  }

  dest="$SSH_HOST_DIR/$name"
  tmp="$(mktemp)"
  trap 'rm -f -- "$tmp"' RETURN

  decrypt_to_temp "$encrypted" "$tmp"

  if ! is_private_key_file "$tmp"; then
    echo "ERROR: decrypted file is not a recognized SSH host private key: $encrypted" >&2
    return 1
  fi

  if "${ROOT[@]}" test -e "$dest"; then
    if "${ROOT[@]}" cmp -s -- "$tmp" "$dest"; then
      "${ROOT[@]}" chmod 600 "$dest"
      "${ROOT[@]}" chown root:root "$dest"
      rm -f -- "$tmp"
      trap - RETURN

      pub_tmp="$(mktemp)"
      trap 'rm -f -- "$pub_tmp"' RETURN
      if ! "${ROOT[@]}" ssh-keygen -y -f "$dest" > "$pub_tmp"; then
        echo "ERROR: failed to derive public host key from restored private key: $dest" >&2
        return 1
      fi
      "${ROOT[@]}" install -o root -g root -m 644 -- "$pub_tmp" "$dest.pub"
      rm -f -- "$pub_tmp"
      trap - RETURN

      echo "unchanged: $dest"
      echo "derived:   $dest.pub"
      return 0
    fi

    if (( FORCE != 1 )); then
      echo "ERROR: refusing to replace different existing host key: $dest" >&2
      echo "Fresh-install recovery normally requires --force because sshd" >&2
      echo "generates replacement host keys during installation." >&2
      return 1
    fi
  fi

  "${ROOT[@]}" install -o root -g root -m 600 -- "$tmp" "$dest"
  rm -f -- "$tmp"
  trap - RETURN

  pub_tmp="$(mktemp)"
  trap 'rm -f -- "$pub_tmp"' RETURN
  if ! "${ROOT[@]}" ssh-keygen -y -f "$dest" > "$pub_tmp"; then
    echo "ERROR: failed to derive public host key from restored private key: $dest" >&2
    return 1
  fi
  "${ROOT[@]}" install -o root -g root -m 644 -- "$pub_tmp" "$dest.pub"
  rm -f -- "$pub_tmp"
  trap - RETURN

  echo "restored:  $dest"
  echo "derived:   $dest.pub"
}

mkdir -p "$SSH_USER_DIR"
chmod 700 "$SSH_USER_DIR"

"${ROOT[@]}" mkdir -p "$SSH_HOST_DIR"

shopt -s nullglob
user_files=("$USER_SOURCE"/*.enc)
host_files=("$HOST_SOURCE"/*.enc)
shopt -u nullglob

if ((${#user_files[@]} == 0 && ${#host_files[@]} == 0)); then
  echo "ERROR: no SOPS-encrypted SSH private credentials found for $MACHINE_ID." >&2
  exit 1
fi

restored_user=0
restored_host=0

for encrypted in "${user_files[@]}"; do
  restore_user_key "$encrypted"
  ((restored_user += 1))
done

for encrypted in "${host_files[@]}"; do
  restore_host_key "$encrypted"
  ((restored_host += 1))
done

echo
echo "Restored SSH credentials from SOPS/age for machine: $MACHINE_ID"
echo "  user private keys: $restored_user"
echo "  host private keys: $restored_host"
echo
echo "Public .pub files were regenerated from the restored private keys."
echo "authorized_keys and SSH config remain declarative Git/Stow state."
