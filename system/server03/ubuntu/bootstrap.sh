#!/usr/bin/env bash

set -euo pipefail

# --------------------------------------------------
# Resolve repo root and machine identity file path
# --------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MACHINE_ID_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id"
EXPECTED_MACHINE="${1:-server03}"
EXPECTED_OS="ubuntu"
MACHINE_LABEL="Terramaster"

# --------------------------------------------------
# Verify machine identity
# --------------------------------------------------
verify_machine_id() {
  if [[ ! -f "$MACHINE_ID_FILE" ]]; then
    echo "✗ Missing machine-id file: $MACHINE_ID_FILE"
    exit 1
  fi

  local actual_machine
  actual_machine="$(<"$MACHINE_ID_FILE")"

  if [[ "$actual_machine" != "$EXPECTED_MACHINE" ]]; then
    echo "✗ Machine identity mismatch"
    echo "  Expected: $EXPECTED_MACHINE"
    echo "  Found:    $actual_machine"
    exit 1
  fi

  echo "✓ Machine identity verified: $actual_machine"
}

# --------------------------------------------------
# Verify operating system
# --------------------------------------------------
verify_os() {
  if ! command -v apt >/dev/null 2>&1; then
    echo "✗ Ubuntu bootstrap called on non-Ubuntu system"
    exit 1
  fi

  echo "✓ Operating system verified: $EXPECTED_OS"
}

# --------------------------------------------------
# Prepare Ubuntu repositories and architecture
# - universe
# - multiverse
# - i386 support
# - package upgrade is performed once later via nala
# --------------------------------------------------
prepare_ubuntu_repos() {
  echo "📦 Preparing Ubuntu repositories and architecture..."

  sudo apt-get update
  sudo apt-get install -y software-properties-common curl ca-certificates gnupg

  sudo add-apt-repository -y universe
  sudo add-apt-repository -y multiverse
  sudo dpkg --add-architecture i386 || true

  echo "✓ Ubuntu repository preparation complete"
}

# --------------------------------------------------
# Ensure nala is available
# --------------------------------------------------
ensure_nala() {
  if command -v nala >/dev/null 2>&1; then
    echo "✓ nala is available"
    return 0
  fi

  echo "📦 nala not found. Installing nala..."
  sudo apt install -y nala
  echo "✓ nala installed"
}

# --------------------------------------------------
# Perform initial system update using nala
# --------------------------------------------------
initial_update() {
  echo "🔄 Performing nala update/upgrade..."
  sudo nala update
  sudo nala upgrade -y
}

# --------------------------------------------------
# Ensure Flatpak is available and Flathub is configured
# - only used if flatpak.txt exists
# --------------------------------------------------
ensure_flatpak() {
  if ! command -v flatpak >/dev/null 2>&1; then
    echo "📦 flatpak not found. Installing flatpak..."
    sudo nala install -y flatpak
  else
    echo "✓ flatpak is available"
  fi

  if ! flatpak remotes --columns=name 2>/dev/null | grep -qx "flathub"; then
    echo "🌐 Adding Flathub remote..."
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  else
    echo "✓ Flathub remote already configured"
  fi

  echo "🔄 Updating Flatpak metadata..."
  flatpak update -y || true
}

# --------------------------------------------------
# Ensure snap is available
# - only used if snap.txt exists
# --------------------------------------------------
ensure_snap() {
  if command -v snap >/dev/null 2>&1; then
    echo "✓ snap is available"
    return 0
  fi

  echo "📦 snap not found. Installing snapd..."
  sudo nala install -y snapd
  sudo systemctl enable --now snapd

  echo "✓ snapd installed and enabled"
}

# --------------------------------------------------
# Wait for snapd readiness before installing snaps
# --------------------------------------------------
wait_for_snap() {
  echo "⏳ Waiting for snapd to become ready..."

  sudo systemctl enable --now snapd

  for _ in {1..20}; do
    if snap version >/dev/null 2>&1; then
      echo "✓ snapd is ready"
      return 0
    fi
    sleep 1
  done

  echo "⚠ snapd did not become ready in time"
}

# --------------------------------------------------
# Ensure Homebrew is available
# - only used if brew.txt exists
# --------------------------------------------------
ensure_brew() {
  if command -v brew >/dev/null 2>&1; then
    echo "✓ Homebrew is available"
    return 0
  fi

  echo "📦 Homebrew not found. Installing Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi

  echo "✓ Homebrew installed"
}


# --------------------------------------------------
# Configure Docker's official APT repository
# - required for docker-ce, containerd.io, Buildx, and Compose plugin
# - idempotent and safe to rerun
# --------------------------------------------------
setup_docker_repo() {
  local codename arch

  echo "🐳 Configuring Docker APT repository..."

  # shellcheck disable=SC1091
  source /etc/os-release
  codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  arch="$(dpkg --print-architecture)"

  if [[ -z "$codename" ]]; then
    echo "✗ Could not determine Ubuntu codename from /etc/os-release"
    exit 1
  fi

  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  echo "✓ Docker APT repository configured"
}

# --------------------------------------------------
# Install packages from machine-specific lists
# - apt.txt
# - snap.txt
# - flatpak.txt
# - brew.txt
# --------------------------------------------------
read_package_file() {
  local file="$1"
  grep -vE '^[[:space:]]*(#|$)' "$file" || true
}

install_packages() {
  local package_dir="$REPO_ROOT/system/$EXPECTED_MACHINE/$EXPECTED_OS"
  local apt_file="$package_dir/apt.txt"
  local snap_file="$package_dir/snap.txt"
  local flatpak_file="$package_dir/flatpak.txt"
  local brew_file="$package_dir/brew.txt"
  local -a packages=()
  local pkg

  if [[ -f "$apt_file" ]]; then
    mapfile -t packages < <(read_package_file "$apt_file")
    if ((${#packages[@]} > 0)); then
      echo "📦 Installing APT packages from $apt_file..."
      sudo nala install -y "${packages[@]}"
    else
      echo "⚠ apt.txt contains no packages, skipping"
    fi
  else
    echo "⚠ No apt.txt found at $apt_file, skipping"
  fi

  packages=()
  if [[ -f "$snap_file" ]]; then
    mapfile -t packages < <(read_package_file "$snap_file")
    if ((${#packages[@]} > 0)); then
      ensure_snap
      wait_for_snap
      echo "📦 Installing Snap packages from $snap_file..."
      for pkg in "${packages[@]}"; do
        sudo snap install "$pkg"
      done
    else
      echo "⚠ snap.txt contains no packages, skipping"
    fi
  fi

  packages=()
  if [[ -f "$flatpak_file" ]]; then
    mapfile -t packages < <(read_package_file "$flatpak_file")
    if ((${#packages[@]} > 0)); then
      ensure_flatpak
      echo "📦 Installing Flatpak packages from $flatpak_file..."
      for pkg in "${packages[@]}"; do
        flatpak install -y flathub "$pkg"
      done
    else
      echo "⚠ flatpak.txt contains no packages, skipping"
    fi
  fi

  packages=()
  if [[ -f "$brew_file" ]]; then
    mapfile -t packages < <(read_package_file "$brew_file")
    if ((${#packages[@]} > 0)); then
      ensure_brew
      if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
      fi
      echo "📦 Installing Homebrew packages from $brew_file..."
      brew update
      for pkg in "${packages[@]}"; do
        if brew list --formula "$pkg" >/dev/null 2>&1; then
          echo "✓ Homebrew package already installed: $pkg"
        else
          brew install "$pkg"
        fi
      done
    else
      echo "⚠ brew.txt contains no packages, skipping"
    fi
  fi
}

# --------------------------------------------------
# Credential reconciliation helpers
# - all credential workflows use the same decision tree:
#     local + repo  -> prompt for authoritative source
#     local only    -> capture
#     repo only     -> restore
#     neither       -> generate + capture
# --------------------------------------------------
choose_authoritative_source() {
  local credential_name="$1"
  local choice

  echo
  echo "⚠ $credential_name credentials exist both locally and in the repository."
  echo "  Choose which copy is authoritative:"
  echo "    [l] local  -> capture local credentials into the repository"
  echo "    [r] repo   -> restore repository credentials onto this machine"
  echo

  while true; do
    read -r -p "Authoritative source [l/r]: " choice
    case "${choice,,}" in
      l|local)
        AUTHORITATIVE_SOURCE="local"
        return 0
        ;;
      r|repo|repository)
        AUTHORITATIVE_SOURCE="repo"
        return 0
        ;;
      *)
        echo "Please enter 'l' for local or 'r' for repo."
        ;;
    esac
  done
}

require_credential_script() {
  local script="$1"

  if [[ ! -f "$script" ]]; then
    echo "✗ Required credential helper is missing: $script"
    exit 1
  fi
}

# --------------------------------------------------
# Setup age + SOPS for encrypted secrets
# - age identity is the root recovery credential
# - reconciles local and repository copies before SOPS-dependent secrets
# --------------------------------------------------
ensure_sops() {
  if command -v sops >/dev/null 2>&1; then
    echo "✓ sops already installed"
    return 0
  fi

  echo "🔐 Installing sops..."

  local architecture sops_version tmp_deb
  architecture="$(dpkg --print-architecture)"

  case "$architecture" in
    amd64|arm64) ;;
    *)
      echo "✗ Unsupported architecture for automatic sops install: $architecture"
      exit 1
      ;;
  esac

  sops_version="$(
    curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest |
      awk -F '"' '/"tag_name"/ {print $4; exit}'
  )"

  if [[ -z "$sops_version" ]]; then
    echo "✗ Failed to determine latest sops version"
    exit 1
  fi

  tmp_deb="$(mktemp --suffix=.deb)"
  curl -fsSL \
    -o "$tmp_deb" \
    "https://github.com/getsops/sops/releases/download/${sops_version}/sops_${sops_version#v}_${architecture}.deb"

  sudo dpkg -i "$tmp_deb"
  rm -f "$tmp_deb"

  echo "✓ sops installed"
}

setup_age_identity() {
  local age_base_dir="${XDG_CONFIG_HOME:-$HOME/.config}/sops"
  local age_dir="$age_base_dir/age"
  local key_file="${SOPS_AGE_KEY_FILE:-$age_dir/keys.txt}"
  local key_dir
  local dotfiles_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles"
  local public_key_file="$dotfiles_dir/age-public-key"
  local machine_id host_secret_dir recovery_file
  local capture_script restore_script public_key backup_file
  local local_exists=0 repo_exists=0

  echo "🔐 Reconciling SOPS age identity..."

  if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
    echo "✗ age/age-keygen not found."
    echo "  Make sure 'age' is present in system/$EXPECTED_MACHINE/$EXPECTED_OS/apt.txt"
    exit 1
  fi

  machine_id="$(tr -d '\r\n' < "$MACHINE_ID_FILE")"
  host_secret_dir="$REPO_ROOT/secrets/$machine_id"
  recovery_file="$host_secret_dir/age-key.age"
  capture_script="$REPO_ROOT/scripts/capture-age-key.sh"
  restore_script="$REPO_ROOT/scripts/restore-age-key.sh"
  key_dir="$(dirname "$key_file")"

  require_credential_script "$capture_script"
  require_credential_script "$restore_script"

  mkdir -p "$key_dir" "$dotfiles_dir" "$age_base_dir"
  chmod 700 "$key_dir" "$age_base_dir"

  if [[ -f "$key_file" ]]; then
    public_key="$(age-keygen -y "$key_file" 2>/dev/null || true)"
    if [[ ! "$public_key" =~ ^age1 ]]; then
      echo "✗ Existing local age identity is invalid: $key_file"
      exit 1
    fi
    local_exists=1
  fi

  [[ -f "$recovery_file" ]] && repo_exists=1

  if (( local_exists && repo_exists )); then
    choose_authoritative_source "age"

    if [[ "$AUTHORITATIVE_SOURCE" == "local" ]]; then
      bash "$capture_script" --force
    else
      # restore-age-key.sh intentionally leaves a valid local identity alone.
      # Move it aside temporarily so the declared repository copy can be
      # restored; put it back if restoration fails.
      backup_file="${key_file}.pre-bootstrap.$$"
      mv "$key_file" "$backup_file"

      if bash "$restore_script"; then
        rm -f "$backup_file"
      else
        mv "$backup_file" "$key_file"
        echo "✗ Repository age restore failed; original local identity restored."
        exit 1
      fi
    fi
  elif (( local_exists )); then
    echo "✓ Local age identity found; no repository recovery copy exists"
    bash "$capture_script"
  elif (( repo_exists )); then
    echo "✓ Repository age recovery copy found; restoring it"
    bash "$restore_script"
  else
    if [[ -d "$host_secret_dir" ]] && \
       find "$host_secret_dir" -type f -name '*.enc' -print -quit | grep -q .; then
      echo "✗ Encrypted secrets exist for $machine_id, but no age identity exists"
      echo "  locally or at: $recovery_file"
      echo "  Refusing to generate an incompatible replacement identity."
      exit 1
    fi

    echo "• No local or repository age identity found; generating a new one..."
    age-keygen -o "$key_file"
    chmod 600 "$key_file"
    bash "$capture_script"
  fi

  chmod 600 "$key_file"
  public_key="$(age-keygen -y "$key_file" 2>/dev/null || true)"

  if [[ ! "$public_key" =~ ^age1 ]]; then
    echo "✗ Failed to derive public age recipient from $key_file"
    exit 1
  fi

  printf '%s\n' "$public_key" > "$public_key_file"
  chmod 644 "$public_key_file"

  AGE_PUBLIC_KEY="$public_key"
  AGE_RECOVERY_FILE="$recovery_file"

  echo "✓ age identity ready"
  echo "  Public key: $public_key"
}

setup_age_and_sops() {
  setup_age_identity
  ensure_sops
  echo "✓ age + sops ready"
}

# --------------------------------------------------
# Reconcile SSH credentials
# - SOPS/age-encrypted private keys are stored under secrets/<machine-id>/ssh
# - user public keys are regenerated by restore-ssh-credentials.sh
# - authorized_keys/config remain declarative dotfiles and are not captured
# --------------------------------------------------
is_user_ssh_private_key() {
  local path="$1"
  local first_line=""

  [[ -f "$path" ]] || return 1

  case "$(basename "$path")" in
    *.pub|*-cert.pub|authorized_keys|authorized_keys2|known_hosts|known_hosts.old|known_hosts.*|config|environment|rc)
      return 1
      ;;
  esac

  IFS= read -r first_line < "$path" || true
  case "$first_line" in
    "-----BEGIN OPENSSH PRIVATE KEY-----"|\
    "-----BEGIN RSA PRIVATE KEY-----"|\
    "-----BEGIN DSA PRIVATE KEY-----"|\
    "-----BEGIN EC PRIVATE KEY-----"|\
    "-----BEGIN PRIVATE KEY-----"|\
    "-----BEGIN ENCRYPTED PRIVATE KEY-----"|\
    "---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

has_local_ssh_credentials() {
  local path

  if [[ -d "$HOME/.ssh" ]]; then
    while IFS= read -r -d '' path; do
      if is_user_ssh_private_key "$path"; then
        return 0
      fi
    done < <(find "$HOME/.ssh" -maxdepth 1 -type f -print0 2>/dev/null)
  fi

  sudo find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*_key' \
    -print -quit 2>/dev/null | grep -q .
}

ensure_local_ssh_credentials() {
  local ssh_dir="$HOME/.ssh"
  local key_file="$ssh_dir/id_ed25519"
  local pub_file="${key_file}.pub"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  # Preserve the original server bootstrap behavior: every server gets a user
  # ed25519 identity, but never overwrite an existing private key.
  if [[ ! -f "$key_file" ]]; then
    echo "• Generating missing user SSH identity..."
    ssh-keygen -t ed25519 \
      -f "$key_file" \
      -N "" \
      -C "$EXPECTED_MACHINE-$(hostname)"
  fi

  chmod 600 "$key_file"

  if [[ ! -f "$pub_file" ]]; then
    ssh-keygen -y -f "$key_file" > "$pub_file"
  fi
  chmod 644 "$pub_file"

  # Generate any missing OpenSSH host-key types without replacing existing
  # host identities.
  sudo ssh-keygen -A
}

reconcile_ssh_credentials() {
  local machine_id ssh_secret_dir capture_script restore_script
  local local_exists=0 repo_exists=0

  echo "🔑 Reconciling SSH credentials..."

  machine_id="$(tr -d '\r\n' < "$MACHINE_ID_FILE")"
  ssh_secret_dir="$REPO_ROOT/secrets/$machine_id/ssh"
  capture_script="$REPO_ROOT/scripts/capture-ssh-credentials.sh"
  restore_script="$REPO_ROOT/scripts/restore-ssh-credentials.sh"

  require_credential_script "$capture_script"
  require_credential_script "$restore_script"

  has_local_ssh_credentials && local_exists=1
  if [[ -d "$ssh_secret_dir" ]] && \
     find "$ssh_secret_dir" -type f -name '*.enc' -print -quit | grep -q .; then
    repo_exists=1
  fi

  if (( local_exists && repo_exists )); then
    choose_authoritative_source "SSH"

    if [[ "$AUTHORITATIVE_SOURCE" == "local" ]]; then
      ensure_local_ssh_credentials
      bash "$capture_script" --force
    else
      bash "$restore_script" --force
    fi
  elif (( local_exists )); then
    echo "✓ Local SSH credentials found; no repository copy exists"
    ensure_local_ssh_credentials
    bash "$capture_script"
  elif (( repo_exists )); then
    echo "✓ Repository SSH credentials found; restoring them"
    bash "$restore_script" --force
  else
    echo "• No local or repository SSH credentials found; generating them..."
    ensure_local_ssh_credentials
    bash "$capture_script"
  fi

  echo "✓ SSH credentials ready"
}

# --------------------------------------------------
# Reconcile WireGuard recovery state
# - recovery artifacts are complete encrypted *.conf files
# - local system config and repository config are compared only for presence
# - when both exist, the user chooses the authoritative source
# - restore stages <interface>.conf + <interface>.public-key under
#   ~/.config/dotfiles/wireguard
# --------------------------------------------------
reconcile_wireguard_credentials() {
  local machine_id wireguard_secret_dir capture_script restore_script
  local system_conf repo_conf staged_conf
  local local_exists=0 repo_exists=0

  echo "🔐 Reconciling WireGuard credentials..."

  if ! command -v wg >/dev/null 2>&1; then
    echo "✗ wg not found. wireguard-tools must be installed first."
    exit 1
  fi

  machine_id="$(tr -d '\r\n' < "$MACHINE_ID_FILE")"
  wireguard_secret_dir="$REPO_ROOT/secrets/$machine_id/wireguard"
  system_conf="/etc/wireguard/wormlogic.conf"
  repo_conf="$wireguard_secret_dir/wormlogic.conf.enc"
  staged_conf="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/wireguard/wormlogic.conf"
  capture_script="$REPO_ROOT/scripts/capture-wireguard-credentials.sh"
  restore_script="$REPO_ROOT/scripts/restore-wireguard-credentials.sh"

  require_credential_script "$capture_script"
  require_credential_script "$restore_script"

  sudo test -f "$system_conf" && local_exists=1
  [[ -f "$repo_conf" ]] && repo_exists=1

  WIREGUARD_GENERATE_NEW=0

  if (( local_exists && repo_exists )); then
    choose_authoritative_source "WireGuard"

    if [[ "$AUTHORITATIVE_SOURCE" == "local" ]]; then
      echo "• Local WireGuard config selected as authoritative"
      bash "$capture_script" --force
      bash "$restore_script" --force
    else
      echo "• Repository WireGuard config selected as authoritative"
      bash "$restore_script" --force
    fi
  elif (( local_exists )); then
    echo "✓ Local WireGuard config found; no repository copy exists"
    bash "$capture_script"
    bash "$restore_script" --force
  elif (( repo_exists )); then
    echo "✓ Repository WireGuard config found; restoring it"
    bash "$restore_script" --force
  else
    echo "• No local or repository WireGuard config found"
    echo "  A new Wormlogic identity will be generated during VPN setup and captured afterward."
    WIREGUARD_GENERATE_NEW=1
    rm -f -- "$staged_conf" "${staged_conf%.conf}.public-key"
  fi

  if (( WIREGUARD_GENERATE_NEW == 0 )) && [[ ! -f "$staged_conf" ]]; then
    echo "✗ WireGuard reconciliation completed without a staged config:"
    echo "  $staged_conf"
    exit 1
  fi

  echo "✓ WireGuard recovery state ready"
}

# --------------------------------------------------
# Set server user environment
# - manage PATH only
# - leave editor/browser choices to OS/user defaults
# --------------------------------------------------
set_user_environment_defaults() {
  local env_dir="$HOME/.config/environment.d"
  local legacy_defaults="$env_dir/defaults.conf"

  echo "🌱 Setting server environment defaults..."

  mkdir -p "$env_dir" "$HOME/.local/bin"

  cat > "$env_dir/path.conf" <<'EOF'
PATH=$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF

  # Older versions of this bootstrap forced nvim. Remove only the exact
  # bootstrap-generated defaults file, leaving other user-managed settings.
  if [[ -f "$legacy_defaults" ]] && \
     [[ "$(grep -vE '^[[:space:]]*(#|$)' "$legacy_defaults" || true)" == $'EDITOR=nvim\nVISUAL=nvim' ]]; then
    rm -f "$legacy_defaults"
    echo "✓ Removed legacy forced nvim environment defaults"
  fi

  if [[ "$(git config --global --get core.editor 2>/dev/null || true)" == "nvim" ]]; then
    git config --global --unset core.editor || true
  fi
  if [[ "$(git config --global --get sequence.editor 2>/dev/null || true)" == "nvim" ]]; then
    git config --global --unset sequence.editor || true
  fi

  echo "✓ Environment defaults configured"
}

# --------------------------------------------------
# Install and enable package export service/timer
# --------------------------------------------------
setup_package_export() {
  echo "⚙ Setting up package export service and timer..."

  mkdir -p "$HOME/.config/systemd/user"
  cp "$REPO_ROOT/systemd/package-export.service" "$HOME/.config/systemd/user/"
  cp "$REPO_ROOT/systemd/package-export.timer" "$HOME/.config/systemd/user/"

  systemctl --user daemon-reload
  systemctl --user enable --now package-export.timer
  systemctl --user start package-export.service || true

  echo "✓ package export service and timer configured"
}

# --------------------------------------------------
# Install and enable scheduled credential capture
# - unit files will be added separately
# - until then, warn and continue without failing bootstrap
# --------------------------------------------------
setup_credential_capture() {
  local service_src="$REPO_ROOT/systemd/credential-capture.service"
  local timer_src="$REPO_ROOT/systemd/credential-capture.timer"
  local user_systemd_dir="$HOME/.config/systemd/user"

  echo "⚙ Setting up scheduled credential capture..."

  if [[ ! -f "$service_src" || ! -f "$timer_src" ]]; then
    CREDENTIAL_CAPTURE_CONFIGURED=0
    echo "⚠ credential-capture.service/timer not present yet; skipping"
    return 0
  fi

  mkdir -p "$user_systemd_dir"
  cp "$service_src" "$user_systemd_dir/"
  cp "$timer_src" "$user_systemd_dir/"

  systemctl --user daemon-reload
  systemctl --user enable --now credential-capture.timer
  CREDENTIAL_CAPTURE_CONFIGURED=1

  echo "✓ credential-capture.timer enabled"
}

# --------------------------------------------------
# Install and enable shared system update service/timer
# --------------------------------------------------
setup_system_update() {
  echo "⚙ Setting up system update service and timer..."

  mkdir -p "$HOME/.config/systemd/user"
  cp "$REPO_ROOT/systemd/system-update.service" "$HOME/.config/systemd/user/"
  cp "$REPO_ROOT/systemd/system-update.timer" "$HOME/.config/systemd/user/"

  systemctl --user daemon-reload
  systemctl --user enable --now system-update.timer

  echo "✓ system-update.timer enabled"
}

# --------------------------------------------------
# Install and enable git monitoring services/timers
# --------------------------------------------------
setup_git_monitoring() {
  echo "⚙ Setting up git monitoring services and timers..."

  mkdir -p "$HOME/.config/systemd/user"
  cp "$REPO_ROOT/systemd/repo-update-check.service" "$HOME/.config/systemd/user/"
  cp "$REPO_ROOT/systemd/repo-update-check.timer" "$HOME/.config/systemd/user/"
  cp "$REPO_ROOT/systemd/dotfiles-change-check.service" "$HOME/.config/systemd/user/"
  cp "$REPO_ROOT/systemd/dotfiles-change-check.timer" "$HOME/.config/systemd/user/"

  systemctl --user daemon-reload
  systemctl --user enable --now repo-update-check.timer
  systemctl --user enable --now dotfiles-change-check.timer

  echo "✓ Git monitoring timers enabled"
}

# --------------------------------------------------
# Setup remote unlock via SSH (Dropbear in initramfs)
# - allows remote LUKS unlock over SSH during boot
# - uses separate Stow-managed preboot authorized keys
# --------------------------------------------------
setup_remote_unlock() {
  local initramfs_authorized_keys="$HOME/.ssh/initramfs_authorized_keys"

  echo "🔐 Setting up remote unlock (dropbear-initramfs)..."

  sudo nala install -y dropbear-initramfs

  if [[ ! -s "$initramfs_authorized_keys" ]]; then
    echo "✗ Initramfs authorized_keys is missing or empty:"
    echo "  $initramfs_authorized_keys"
    echo "  Remote unlock cannot be configured."
    exit 1
  fi

  sudo mkdir -p /etc/dropbear/initramfs

  echo "✓ Found initramfs authorized_keys, installing into initramfs"

  sudo cp \
    "$initramfs_authorized_keys" \
    /etc/dropbear/initramfs/authorized_keys

  sudo chmod 600 /etc/dropbear/initramfs/authorized_keys
  sudo chown root:root /etc/dropbear/initramfs/authorized_keys

  sudo sed -i 's/^#\?IP=.*/IP=dhcp/' /etc/initramfs-tools/initramfs.conf

  sudo tee /etc/dropbear/initramfs/dropbear.conf >/dev/null <<'EOF'
DROPBEAR_OPTIONS="-p 2222 -s -j -k -I 60"
EOF

  sudo update-initramfs -u

  echo "✓ Remote unlock configured"
}

# --------------------------------------------------
# Install and enable shared monitoring services/timers
# - disk-space-check
#- heartbeat
# --------------------------------------------------
setup_shared_monitoring() {
  echo "⚙ Setting up shared monitoring services and timers..."

  mkdir -p "$HOME/.config/systemd/user"

  cp "$REPO_ROOT/systemd/disk-space-check.service" "$HOME/.config/systemd/user/"
  cp "$REPO_ROOT/systemd/disk-space-check.timer" "$HOME/.config/systemd/user/"
  cp "$REPO_ROOT/systemd/heartbeat.service" "$HOME/.config/systemd/user/"
  cp "$REPO_ROOT/systemd/heartbeat.timer" "$HOME/.config/systemd/user/"

  systemctl --user daemon-reload
  systemctl --user enable --now disk-space-check.timer
  systemctl --user enable --now heartbeat.timer

  echo "✓ Shared monitoring timers enabled"
}

# --------------------------------------------------
# Install Starship prompt
# --------------------------------------------------
install_starship() {
  if command -v starship >/dev/null 2>&1; then
    echo "✓ starship already installed"
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "✗ curl is required to install starship"
    exit 1
  fi

  echo "🚀 Installing starship..."
  curl -sS https://starship.rs/install.sh | sh -s -- -y

  echo "✓ starship installed"
}

# --------------------------------------------------
# Setup Wormlogic WireGuard peer
# - consumes the complete config staged by recovery for the existing identity
# - if no identity exists anywhere, generates a new private key once
# - after final configuration, captures the complete live config and restores
#   staging so repository, live state, and derived public key agree
# --------------------------------------------------
read_wireguard_private_key() {
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
  ' "$config_file" | tr -d '[:space:]'
}

setup_wormlogic_vpn() {
  local vpn_name="wormlogic"
  local vps_host="vpn.wormlogic.com"
  local vpn_allowed_ips="10.8.0.1/32"
  local machine_id_file="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id"

  local machine_id
  local local_dir
  local credential_dir
  local staged_conf
  local staged_public
  local local_public_file
  local source_conf
  local target_conf
  local settings_file
  local capture_script
  local restore_script

  local peer_private_key
  local peer_vpn_ip
  local vps_public_key

  echo "🔐 Setting up Wormlogic WireGuard peer..."

  if [[ ! -f "$machine_id_file" ]]; then
    echo "✗ Missing machine-id file: $machine_id_file"
    exit 1
  fi

  machine_id="$(tr -d '\r\n' < "$machine_id_file")"

  local_dir="$REPO_ROOT/local/wireguard"
  credential_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/wireguard"
  staged_conf="$credential_dir/${vpn_name}.conf"
  staged_public="$credential_dir/${vpn_name}.public-key"
  local_public_file="$local_dir/${machine_id}.pub"
  source_conf="$local_dir/$vpn_name.conf"
  target_conf="/etc/wireguard/$vpn_name.conf"
  settings_file="$local_dir/$vpn_name.env"
  capture_script="$REPO_ROOT/scripts/capture-wireguard-credentials.sh"
  restore_script="$REPO_ROOT/scripts/restore-wireguard-credentials.sh"

  if ! command -v wg >/dev/null 2>&1; then
    echo "✗ wg not found. wireguard-tools must be installed first."
    exit 1
  fi

  require_credential_script "$capture_script"
  require_credential_script "$restore_script"

  mkdir -p "$local_dir" "$credential_dir"
  chmod 700 "$REPO_ROOT/local" "$local_dir" "$credential_dir"

  if [[ -f "$staged_conf" ]]; then
    peer_private_key="$(read_wireguard_private_key "$staged_conf")"
    if [[ -z "$peer_private_key" ]]; then
      echo "✗ Recovered WireGuard config has no PrivateKey: $staged_conf"
      exit 1
    fi
  elif [[ "${WIREGUARD_GENERATE_NEW:-0}" -eq 1 ]]; then
    echo "• Generating new WireGuard identity for $machine_id..."
    peer_private_key="$(wg genkey)"
  else
    echo "✗ Reconciled WireGuard config is missing: $staged_conf"
    exit 1
  fi

  if ! printf '%s\n' "$peer_private_key" | wg pubkey >/dev/null 2>&1; then
    echo "✗ Wormlogic PrivateKey is invalid"
    exit 1
  fi

  if [[ -f "$settings_file" ]]; then
    # shellcheck disable=SC1090
    source "$settings_file"
  fi

  if [[ -z "${WORMLOGIC_VPS_PUBLIC_KEY:-}" ]]; then
    echo
    echo "Enter VPS WireGuard public key."
    echo "Get it from the VPS with:"
    echo "  sudo awk '/PrivateKey/ {print \$3}' /etc/wireguard/wg0.conf | wg pubkey"
    echo
    read -r -p "VPS public key: " WORMLOGIC_VPS_PUBLIC_KEY
  fi

  local default_vpn_ip="10.8.0.5/32"
  if [[ -z "${WORMLOGIC_VPN_IP:-}" ]]; then
    echo
    read -r -p "$EXPECTED_MACHINE VPN IP [$default_vpn_ip]: " input_vpn_ip
    WORMLOGIC_VPN_IP="${input_vpn_ip:-$default_vpn_ip}"
  fi

  vps_public_key="$WORMLOGIC_VPS_PUBLIC_KEY"
  peer_vpn_ip="$WORMLOGIC_VPN_IP"

  if ! printf '%s' "$vps_public_key" | wg pubkey >/dev/null 2>&1; then
    echo "✗ Invalid VPS public key"
    exit 1
  fi

  if [[ ! "$peer_vpn_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    echo "✗ Invalid VPN IP: $peer_vpn_ip"
    exit 1
  fi

  {
    echo "WORMLOGIC_VPS_PUBLIC_KEY='$vps_public_key'"
    echo "WORMLOGIC_VPN_IP='$peer_vpn_ip'"
  } > "$settings_file"
  chmod 600 "$settings_file"

  echo "• Writing WireGuard config: $source_conf"
  {
    echo "[Interface]"
    echo "PrivateKey = $peer_private_key"
    echo "Address = $peer_vpn_ip"
    echo
    echo "[Peer]"
    echo "PublicKey = $vps_public_key"
    echo "Endpoint = $vps_host:51820"
    echo "AllowedIPs = $vpn_allowed_ips"
    echo "PersistentKeepalive = 25"
  } > "$source_conf"
  chmod 600 "$source_conf"

  echo "• Installing config to: $target_conf"
  sudo install -d -m 700 /etc/wireguard
  sudo install -m 600 "$source_conf" "$target_conf"

  # At this point the live config is authoritative: it contains the selected
  # identity plus the current bootstrap's address, peer, endpoint, and routes.
  # Capture that complete config, then restore staging to derive its public key.
  bash "$capture_script" --force
  bash "$restore_script" --force

  if [[ ! -f "$staged_public" ]]; then
    echo "✗ WireGuard restore did not produce the expected public key:"
    echo "  $staged_public"
    exit 1
  fi

  install -m 0644 "$staged_public" "$local_public_file"

  sudo systemctl enable --now "wg-quick@$vpn_name"

  WORMLOGIC_VPN_MACHINE_ID="$machine_id"
  WORMLOGIC_VPN_PUBLIC_KEY="$(tr -d '\r\n' < "$staged_public")"
  WORMLOGIC_VPN_IP="$peer_vpn_ip"

  echo "✓ Wormlogic WireGuard peer configured"
  echo "  Machine:       $machine_id"
  echo "  VPN IP:        $peer_vpn_ip"
  echo "  Source config: $source_conf"
  echo "  System config: $target_conf"
}

# --------------------------------------------------
# Apply optional machine-specific system configuration
# --------------------------------------------------
configure_host_system() {
  local configure_script="$REPO_ROOT/system/$EXPECTED_MACHINE/$EXPECTED_OS/configure-system.sh"

  if [[ ! -f "$configure_script" ]]; then
    echo "⚠ No host-specific system configuration at $configure_script, skipping"
    return 0
  fi

  echo "⚙ Applying host-specific system configuration..."
  bash "$configure_script"
}

# --------------------------------------------------
# Prepare shell dotfiles for stow
# - back up regular files
# - leave symlinks alone
# --------------------------------------------------
prepare_shell_dotfiles() {
  local backup_dir="$HOME/.dotfile-backups/$(date +%Y%m%d-%H%M%S)"
  local files=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_logout" "$HOME/.ssh/config" "$HOME/.ssh/authorized_keys")

  echo "🐚 Preparing shell dotfiles for stow..."

  for file in "${files[@]}"; do
    if [[ -L "$file" ]]; then
      echo "✓ $file is already a symlink, leaving it alone"
    elif [[ -f "$file" ]]; then
      mkdir -p "$backup_dir"
      mv "$file" "$backup_dir/"
      echo "✓ Backed up $(basename "$file") to $backup_dir"
    else
      echo "• $file not present, nothing to do"
    fi
  done
}

# --------------------------------------------------
# Apply host-specific environment overrides
# --------------------------------------------------
apply_host_environment() {
  local host_dir="$REPO_ROOT/hosts/$EXPECTED_MACHINE/$EXPECTED_OS"

  if [[ ! -d "$host_dir" ]]; then
    echo "⚠ No host-specific environment found at $host_dir, skipping"
    return 0
  fi

  echo "🌱 Applying host-specific environment from $host_dir..."

  for dir in "$host_dir"/*; do
    if [[ -d "$dir" ]]; then
      local name
      name="$(basename "$dir")"
      echo "🔗 Stowing host package: $name"
      stow -d "$host_dir" -t "$HOME" "$name"
    fi
  done
}

# --------------------------------------------------
# Run initial package export
# --------------------------------------------------
run_package_export() {
  local export_script="$REPO_ROOT/scripts/package-export.sh"

  if [[ ! -f "$export_script" ]]; then
    echo "⚠ package-export.sh not found at $export_script, skipping"
    return 0
  fi

  echo "📝 Exporting current package state..."
  bash "$export_script"
}

# --------------------------------------------------
# Display final summary
# --------------------------------------------------
show_summary() {
  local git_name git_email local_ip

  git_name="$(git config --global user.name || echo "unset")"
  git_email="$(git config --global user.email || echo "unset")"
  local_ip="$( (ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}') || true)"
  local_ip="${local_ip:-unavailable}"

  echo
  echo "=================================================="
  echo "✓ Bootstrap complete for $MACHINE_LABEL ($EXPECTED_MACHINE)"
  echo "=================================================="
  echo

  if command -v neofetch >/dev/null 2>&1; then
    neofetch
    echo
  fi

  echo "Git user:"
  echo "  Name:  $git_name"
  echo "  Email: $git_email"
  echo
  echo "Local IP:"
  echo "  $local_ip"
  echo
  echo "SOPS age identity:"
  echo "  Public key: ${AGE_PUBLIC_KEY:-unavailable}"
  if [[ -n "${AGE_RECOVERY_FILE:-}" && ! -f "${AGE_RECOVERY_FILE:-}" ]]; then
    echo "  Recovery:   not captured yet"
    echo "  Action:     ./scripts/capture-age-key.sh"
  else
    echo "  Recovery:   ${AGE_RECOVERY_FILE:-unavailable}"
  fi
  echo
  echo "WireGuard (Wormlogic peer):"

  if [[ -n "${WORMLOGIC_VPN_PUBLIC_KEY:-}" ]]; then
    echo "  Interface: wormlogic"
    echo "  VPN IP:    ${WORMLOGIC_VPN_IP:-unknown}"
    echo
    echo "⚠ Action required on VPS:"
    echo
    echo "Add this peer to /etc/wireguard/wg0.conf:"
    echo
    echo "  # ${WORMLOGIC_VPN_MACHINE_ID:-$EXPECTED_MACHINE}"
    echo "  [Peer]"
    echo "  PublicKey = $WORMLOGIC_VPN_PUBLIC_KEY"
    echo "  AllowedIPs = ${WORMLOGIC_VPN_IP:-REPLACE_WITH_VPN_IP}"
    echo
    echo "Then restart WireGuard on the VPS:"
    echo "  sudo systemctl restart wg-quick@wg0"
  fi
  echo
}

# --------------------------------------------------
# Prompt for reboot
# --------------------------------------------------
prompt_reboot() {
  echo "Press Enter to reboot..."
  read -r
  sudo reboot
}

# --------------------------------------------------
# Main bootstrap flow
# --------------------------------------------------
main() {
  echo "🚀 Starting bootstrap for $MACHINE_LABEL ($EXPECTED_MACHINE)..."
  echo

  verify_machine_id
  verify_os
  prepare_ubuntu_repos
  ensure_nala
  setup_docker_repo
  initial_update
  install_packages
  setup_age_and_sops
  reconcile_ssh_credentials
  reconcile_wireguard_credentials
  install_starship
  set_user_environment_defaults
  setup_wormlogic_vpn
  configure_host_system
  setup_package_export
  setup_credential_capture
  setup_system_update
  setup_git_monitoring
  setup_shared_monitoring
  prepare_shell_dotfiles
  apply_host_environment
  setup_remote_unlock
  run_package_export
  show_summary

  echo
  echo "📊 Services configured:"
  echo "   - package-export        → state tracking (runs now + daily)"
  if [[ "${CREDENTIAL_CAPTURE_CONFIGURED:-0}" -eq 1 ]]; then
    echo "   - credential-capture    → encrypted credential state capture (scheduled)"
  else
    echo "   - credential-capture    → pending service/timer unit files"
  fi
  echo "   - system-update         → system maintenance (scheduled)"
  echo "   - repo-update-check     → remote update awareness (daily)"
  echo "   - dotfiles-change-check → local dotfiles drift awareness (daily)"
  echo "   - disk-space-check      → local disk usage warning (daily)"
  echo "   - heartbeat             → device online signal (daily)"
  echo

  prompt_reboot
}

main "$@"
