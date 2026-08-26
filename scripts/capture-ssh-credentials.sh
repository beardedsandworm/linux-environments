#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Capture locally-owned SSH private credentials for this machine and encrypt
# each one with SOPS using the machine's existing age identity.
#
# Repository layout:
#   secrets/<machine-id>/ssh/user/<filename>.enc
#   secrets/<machine-id>/ssh/host/<filename>.enc
#
# Captured:
#   - Private SSH keys in ~/.ssh (including arbitrarily named keys)
#   - OpenSSH host private keys matching /etc/ssh/ssh_host_*_key
#
# Deliberately NOT captured:
#   - ~/.ssh/authorized_keys   (declarative Git/Stow state)
#   - ~/.ssh/config            (declarative Git/Stow state)
#   - ~/.ssh/known_hosts*      (learned/disposable state)
#   - *.pub / *-cert.pub       (public, not secret)
#
# This script does not generate SSH keys. Bootstrap logic can decide whether
# to restore existing credentials or generate new credentials and capture them.

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
Usage: capture-ssh-credentials.sh [options]

Options:
  --repo-root PATH       Dotfiles repository root.
  --machine-id ID        Override machine ID instead of reading machine-id file.
  --age-key PATH         SOPS age identity file.
  --user-ssh-dir PATH    User SSH directory (default: ~/.ssh).
  --host-ssh-dir PATH    Host SSH directory (default: /etc/ssh).
  --force                Replace an encrypted credential only if its plaintext
                         differs from the credential currently in the repo.
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
need_cmd age-keygen
need_cmd mktemp
need_cmd cmp
need_cmd find
need_cmd head

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
  echo "ERROR: could not derive an age recipient from: $AGE_KEY_FILE" >&2
  exit 1
}

[[ "$AGE_RECIPIENT" == age1* ]] || {
  echo "ERROR: derived age recipient is not valid." >&2
  exit 1
}

DEST_ROOT="$REPO_ROOT/secrets/$MACHINE_ID/ssh"
USER_DEST="$DEST_ROOT/user"
HOST_DEST="$DEST_ROOT/host"
mkdir -p "$USER_DEST" "$HOST_DEST"

if (( EUID == 0 )); then
  ROOT=()
else
  command -v sudo >/dev/null 2>&1 || {
    echo "ERROR: sudo is required to read OpenSSH host private keys." >&2
    exit 1
  }
  ROOT=(sudo)
fi

is_private_key_stream() {
  local first_line
  IFS= read -r first_line || true

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

is_user_private_key() {
  local path="$1"
  [[ -f "$path" ]] || return 1

  # Fast exclusions for files that are definitely not private identity keys.
  case "$(basename -- "$path")" in
    *.pub | *-cert.pub | authorized_keys | authorized_keys2 | \
    known_hosts | known_hosts.old | known_hosts.* | \
    config | environment | rc)
      return 1
      ;;
  esac

  head -n 1 -- "$path" | is_private_key_stream
}

sops_decrypt_to_temp() {
  local encrypted="$1"
  local tmp="$2"

  SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
    sops decrypt \
      --input-type json \
      --output-type binary \
      "$encrypted" > "$tmp"
}

encrypt_file_atomic() {
  local source="$1"
  local dest="$2"
  local use_sudo="${3:-0}"
  local tmp encrypted_plain

  if [[ -e "$dest" ]]; then
    encrypted_plain="$(mktemp)"
    trap 'rm -f -- "$encrypted_plain"' RETURN

    if ! sops_decrypt_to_temp "$dest" "$encrypted_plain"; then
      echo "ERROR: existing encrypted credential cannot be decrypted: $dest" >&2
      return 1
    fi

    if (( use_sudo )); then
      if "${ROOT[@]}" cmp -s -- "$source" "$encrypted_plain"; then
        rm -f -- "$encrypted_plain"
        trap - RETURN
        echo "unchanged: $dest"
        return 0
      fi
    else
      if cmp -s -- "$source" "$encrypted_plain"; then
        rm -f -- "$encrypted_plain"
        trap - RETURN
        echo "unchanged: $dest"
        return 0
      fi
    fi

    rm -f -- "$encrypted_plain"
    trap - RETURN

    if (( FORCE != 1 )); then
      echo "ERROR: $dest already exists but contains different key material." >&2
      echo "Use --force only when intentionally replacing the repository copy." >&2
      return 1
    fi
  fi

  tmp="$(mktemp "${dest}.tmp.XXXXXX")"
  trap 'rm -f -- "$tmp"' RETURN

  if (( use_sudo )); then
    "${ROOT[@]}" cat -- "$source" \
      | sops encrypt \
          --age "$AGE_RECIPIENT" \
          --input-type binary \
          --output-type json \
          /dev/stdin > "$tmp"
  else
    cat -- "$source" \
      | sops encrypt \
          --age "$AGE_RECIPIENT" \
          --input-type binary \
          --output-type json \
          /dev/stdin > "$tmp"
  fi

  chmod 600 "$tmp"
  mv -f -- "$tmp" "$dest"
  trap - RETURN
  echo "captured:  $dest"
}

captured_user=0
captured_host=0

if [[ -d "$SSH_USER_DIR" ]]; then
  while IFS= read -r -d '' path; do
    if is_user_private_key "$path"; then
      name="$(basename -- "$path")"
      [[ "$name" =~ ^[A-Za-z0-9._@+-]+$ ]] || {
        echo "ERROR: refusing unsafe SSH key filename: $name" >&2
        exit 1
      }

      encrypt_file_atomic "$path" "$USER_DEST/$name.enc" 0
      ((captured_user += 1))
    fi
  done < <(find "$SSH_USER_DIR" -maxdepth 1 -type f -print0 | sort -z)
fi

# OpenSSH host private keys are conventionally root-owned and have predictable
# names. Public .pub companions do not match this glob.
if "${ROOT[@]}" test -d "$SSH_HOST_DIR"; then
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    name="$(basename -- "$path")"

    [[ "$name" =~ ^ssh_host_[A-Za-z0-9_.-]+_key$ ]] || {
      echo "ERROR: refusing unexpected host-key filename: $name" >&2
      exit 1
    }

    encrypt_file_atomic "$path" "$HOST_DEST/$name.enc" 1
    ((captured_host += 1))
  done < <("${ROOT[@]}" find "$SSH_HOST_DIR" -maxdepth 1 -type f -name 'ssh_host_*_key' -print 2>/dev/null | sort)
fi

if (( captured_user == 0 && captured_host == 0 )); then
  echo "ERROR: no SSH private credentials were found to capture." >&2
  exit 1
fi

echo
echo "Captured SSH credentials with SOPS/age for machine: $MACHINE_ID"
echo "  user private keys: $captured_user"
echo "  host private keys: $captured_host"
echo "  repository path:   $DEST_ROOT"
