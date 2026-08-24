#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MACHINE_ID_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id"

EXPECTED_MACHINE="${1:-vps01}"
EXPECTED_OS="ubuntu"
MACHINE_LABEL="Heighliner VPS"

if [[ $EUID -eq 0 ]]; then
  echo "✗ Run this bootstrap as the normal user, not as root."
  echo "  The script uses sudo where root access is required."
  exit 1
fi

verify_machine_id() {
  if [[ ! -f "$MACHINE_ID_FILE" ]]; then
    echo "✗ Missing machine-id file: $MACHINE_ID_FILE"
    exit 1
  fi

  local actual_machine
  actual_machine="$(tr -d '\r\n' < "$MACHINE_ID_FILE")"

  if [[ "$actual_machine" != "$EXPECTED_MACHINE" ]]; then
    echo "✗ Machine identity mismatch"
    echo "  Expected: $EXPECTED_MACHINE"
    echo "  Found:    $actual_machine"
    exit 1
  fi

  echo "✓ Machine identity verified: $actual_machine"
}

verify_os() {
  if [[ ! -r /etc/os-release ]]; then
    echo "✗ Cannot identify operating system"
    exit 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "$EXPECTED_OS" ]]; then
    echo "✗ Ubuntu bootstrap called on ${ID:-unknown}"
    exit 1
  fi

  echo "✓ Operating system verified: $EXPECTED_OS"
}

prepare_ubuntu_repos() {
  echo "📦 Preparing Ubuntu repositories..."

  sudo apt-get update
  sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    software-properties-common

  sudo add-apt-repository -y universe
  sudo add-apt-repository -y multiverse

  echo "✓ Ubuntu repositories ready"
}

ensure_nala() {
  if command -v nala >/dev/null 2>&1; then
    echo "✓ nala is available"
    return 0
  fi

  echo "📦 Installing nala..."
  sudo apt-get update
  sudo apt-get install -y nala
}

install_docker_repo() {
  echo "🐳 Configuring Docker apt repository..."

  local codename architecture
  # shellcheck disable=SC1091
  source /etc/os-release
  codename="${VERSION_CODENAME:?Missing VERSION_CODENAME in /etc/os-release}"
  architecture="$(dpkg --print-architecture)"

  sudo install -d -m 0755 /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor | \
    sudo tee /etc/apt/keyrings/docker.gpg >/dev/null

  sudo chmod 0644 /etc/apt/keyrings/docker.gpg

  printf '%s\n' \
    "deb [arch=$architecture signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $codename stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  echo "✓ Docker apt repository configured"
}

initial_update() {
  echo "📦 Updating system..."
  sudo nala update
  sudo nala upgrade -y
}

install_packages() {
  local package_dir="$REPO_ROOT/system/$EXPECTED_MACHINE/$EXPECTED_OS"
  local apt_file="$package_dir/apt.txt"
  local -a apt_packages=()

  if [[ ! -f "$apt_file" ]]; then
    echo "⚠ No apt.txt found at $apt_file, skipping"
    return 0
  fi

  echo "📦 Installing packages from $apt_file..."
  mapfile -t apt_packages < <(grep -vE '^[[:space:]]*(#|$)' "$apt_file")

  if ((${#apt_packages[@]} == 0)); then
    echo "⚠ apt.txt exists but contains no packages"
    return 0
  fi

  sudo nala install -y "${apt_packages[@]}"
}

install_docker_engine() {
  echo "🐳 Ensuring Docker Engine is installed..."

  sudo nala install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER"

  echo "✓ Docker Engine ready"
}

ensure_sops() {
  if command -v sops >/dev/null 2>&1; then
    echo "✓ sops already installed"
    return 0
  fi

  echo "🔐 Installing sops..."

  local architecture sops_version
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

  curl -fsSL \
    -o /tmp/sops.deb \
    "https://github.com/getsops/sops/releases/download/${sops_version}/sops_${sops_version#v}_${architecture}.deb"

  sudo dpkg -i /tmp/sops.deb
  rm -f /tmp/sops.deb
}

setup_age_identity() {
  local age_base_dir="${XDG_CONFIG_HOME:-$HOME/.config}/sops"
  local age_dir="$age_base_dir/age"
  local key_file="$age_dir/keys.txt"
  local dotfiles_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles"
  local public_key_file="$dotfiles_dir/age-public-key"
  local host_secret_dir="$REPO_ROOT/secrets/$EXPECTED_MACHINE"
  local age_recovery_file="$host_secret_dir/age-key.age"
  local age_restore_script="$REPO_ROOT/scripts/restore-age-key.sh"
  local public_key=""

  echo "🔐 Restoring/creating SOPS age identity..."

  if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
    echo "✗ age/age-keygen not found. Ensure 'age' is installed by apt.txt."
    exit 1
  fi

  mkdir -p "$age_dir" "$dotfiles_dir"
  chmod 700 "$age_base_dir" "$age_dir"

  # Recovery is attempted before generating a new identity. The recovery blob
  # is passphrase-encrypted with age itself, so this step does not depend on SOPS.
  if [[ ! -f "$key_file" && -f "$age_recovery_file" ]]; then
    if [[ ! -x "$age_restore_script" ]]; then
      echo "✗ Age recovery exists but restore helper is missing or not executable:"
      echo "  $age_restore_script"
      exit 1
    fi

    echo "🔐 Stored age recovery identity found for $EXPECTED_MACHINE"
    "$age_restore_script"
  fi

  if [[ ! -f "$key_file" ]]; then
    if [[ -d "$host_secret_dir" ]] && \
       find "$host_secret_dir" -maxdepth 1 -type f -name '*.enc' -print -quit | grep -q .; then
      echo "✗ Encrypted host secrets exist, but this machine has no SOPS age private key."
      echo "  Expected recovery copy: $age_recovery_file"
      echo "  Refusing to generate an incompatible replacement identity."
      exit 1
    fi

    age-keygen -o "$key_file"
    echo "✓ New age identity generated"
    echo "  After bootstrap, run scripts/capture-age-key.sh to escrow it."
  else
    echo "✓ Existing/restored age identity found"
  fi

  chmod 600 "$key_file"
  public_key="$(age-keygen -y "$key_file" 2>/dev/null || true)"

  if [[ ! "$public_key" =~ ^age1 ]]; then
    echo "✗ Failed to derive public age recipient from $key_file"
    exit 1
  fi

  printf '%s\n' "$public_key" > "$public_key_file"
  chmod 644 "$public_key_file"

  echo "✓ age identity ready"
  echo "  Public key:  $public_key"
  echo "  Private key: $key_file"
}

setup_age_and_sops() {
  setup_age_identity
  ensure_sops
  echo "✓ age + sops ready"
}

ensure_ssh_key() {
  local ssh_dir="$HOME/.ssh"
  local key_file="$ssh_dir/id_ed25519"
  local pub_file="${key_file}.pub"

  echo "🔑 Checking for SSH key..."

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  if [[ -f "$pub_file" ]]; then
    echo "✓ SSH public key already exists"
    return 0
  fi

  if [[ -f "$key_file" ]]; then
    ssh-keygen -y -f "$key_file" > "$pub_file"
    chmod 644 "$pub_file"
    echo "✓ SSH public key regenerated from private key"
    return 0
  fi

  ssh-keygen -t ed25519 -f "$key_file" -N "" -C "$EXPECTED_MACHINE-$(hostname)"
  chmod 600 "$key_file"
  chmod 644 "$pub_file"

  echo "✓ SSH key generated"
}

install_starship() {
  if command -v starship >/dev/null 2>&1; then
    echo "✓ starship already installed"
    return 0
  fi

  echo "⭐ Installing starship..."
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y
}

set_user_environment_defaults() {
  echo "⚙ Setting user environment defaults..."

  mkdir -p "$HOME/.config/environment.d" "$HOME/.local/bin"

  cat > "$HOME/.config/environment.d/path.conf" <<EOF_PATH
PATH=$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF_PATH

  # Servers use OS/tool defaults. Do not force EDITOR, VISUAL, BROWSER, or Git
  # editor values from the bootstrap.
  rm -f "$HOME/.config/environment.d/defaults.conf"

  echo "✓ Environment defaults configured"
}

configure_host_system() {
  local script="$REPO_ROOT/system/$EXPECTED_MACHINE/$EXPECTED_OS/configure-system.sh"

  if [[ ! -x "$script" ]]; then
    echo "⚠ No executable host system configuration at $script, skipping"
    return 0
  fi

  echo "⚙ Applying host-specific system configuration..."
  "$script"
}

user_systemd_available() {
  systemctl --user status >/dev/null 2>&1
}

setup_user_service_pair() {
  local name="$1"
  local service_source="$REPO_ROOT/systemd/${name}.service"
  local timer_source="$REPO_ROOT/systemd/${name}.timer"

  if ! user_systemd_available; then
    echo "⚠ User systemd unavailable; skipping $name"
    return 0
  fi

  if [[ ! -f "$service_source" || ! -f "$timer_source" ]]; then
    echo "⚠ Missing systemd files for $name, skipping"
    return 0
  fi

  mkdir -p "$HOME/.config/systemd/user"
  install -m 0644 "$service_source" "$HOME/.config/systemd/user/${name}.service"
  install -m 0644 "$timer_source" "$HOME/.config/systemd/user/${name}.timer"

  systemctl --user daemon-reload
  systemctl --user enable --now "${name}.timer"
}

setup_package_export() {
  echo "⚙ Setting up package export service and timer..."
  setup_user_service_pair "package-export"
}

setup_system_update() {
  echo "⚙ Setting up system update service and timer..."
  setup_user_service_pair "system-update"
}

setup_git_monitoring() {
  echo "⚙ Setting up git monitoring services and timers..."
  setup_user_service_pair "repo-update-check"
  setup_user_service_pair "dotfiles-change-check"
}

setup_shared_monitoring() {
  echo "⚙ Setting up shared monitoring services and timers..."
  setup_user_service_pair "disk-space-check"
  setup_user_service_pair "heartbeat"
}

prepare_shell_dotfiles() {
  local backup_dir="$HOME/.dotfile-backups/$(date +%Y%m%d-%H%M%S)"
  local files=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_logout")

  echo "🐚 Preparing shell dotfiles for stow..."

  local file
  for file in "${files[@]}"; do
    if [[ -L "$file" ]]; then
      echo "✓ $file is already a symlink"
    elif [[ -f "$file" ]]; then
      mkdir -p "$backup_dir"
      mv "$file" "$backup_dir/"
      echo "✓ Backed up $(basename "$file")"
    fi
  done
}

apply_bash_stow() {
  local stow_dir="$REPO_ROOT/stow"

  if [[ ! -d "$stow_dir/bash" ]]; then
    echo "⚠ Bash stow package not found at $stow_dir/bash, skipping"
    return 0
  fi

  echo "🐚 Stowing bash config..."
  stow -d "$stow_dir" -t "$HOME" bash
}

apply_host_environment() {
  local host_dir="$REPO_ROOT/hosts/$EXPECTED_MACHINE/$EXPECTED_OS"

  if [[ ! -d "$host_dir" ]]; then
    echo "⚠ No host-specific environment found at $host_dir, skipping"
    return 0
  fi

  echo "⚙ Applying host-specific environment from $host_dir..."

  local dir name
  for dir in "$host_dir"/*; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    stow -d "$host_dir" -t "$HOME" "$name"
  done
}

run_package_export() {
  if [[ -x "$REPO_ROOT/scripts/package-export.sh" ]]; then
    echo "📦 Exporting current package state..."
    "$REPO_ROOT/scripts/package-export.sh"
  else
    echo "⚠ package-export.sh not found or not executable, skipping"
  fi
}

show_summary() {
  local git_name git_email local_ip

  git_name="$(git config --global user.name 2>/dev/null || echo "unset")"
  git_email="$(git config --global user.email 2>/dev/null || echo "unset")"
  local_ip="$(
    ip route get 1.1.1.1 2>/dev/null |
      awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true
  )"
  local_ip="${local_ip:-unavailable}"

  echo
  echo "=================================================="
  echo "✓ Bootstrap complete for $MACHINE_LABEL ($EXPECTED_MACHINE)"
  echo "=================================================="
  echo
  echo "Git user:"
  echo "  Name:  $git_name"
  echo "  Email: $git_email"
  echo
  echo "Local IP:"
  echo "  $local_ip"
  echo
  echo "Services configured:"
  echo "  - package-export        → state tracking"
  echo "  - system-update         → scheduled system maintenance"
  echo "  - repo-update-check     → remote update awareness"
  echo "  - dotfiles-change-check → local dotfiles drift awareness"
  echo "  - disk-space-check      → local disk usage warning"
  echo "  - heartbeat             → device online signal"
  echo
  echo "Docker:"
  docker --version || true
  docker compose version || true

  if systemctl is-enabled --quiet wg-quick@wg0.service 2>/dev/null; then
    echo
    echo "Wormlogic tunnel:"
    echo "  - wg0:          $(systemctl is-active wg-quick@wg0.service 2>/dev/null || true)"
    echo "  - forwarding:   $(systemctl is-active wormlogic-wg.service 2>/dev/null || true)"
  fi

  if systemctl is-enabled --quiet wg-quick@wg-pvp.service 2>/dev/null; then
    echo
    echo "PVP gateway:"
    echo "  - wg-pvp:       $(systemctl is-active wg-quick@wg-pvp.service 2>/dev/null || true)"
    echo "  - wg-proton:    $(systemctl is-active wg-quick@wg-proton.service 2>/dev/null || true)"
    echo "  - policy layer: $(systemctl is-active wormlogic-pvp.service 2>/dev/null || true)"
  fi
}

prompt_reboot() {
  local answer=""

  echo
  read -r -p "Reboot now? [y/N] " answer

  case "$answer" in
    y|Y|yes|YES) sudo reboot ;;
    *) echo "• Reboot skipped" ;;
  esac
}

main() {
  echo "🚀 Starting bootstrap for $MACHINE_LABEL ($EXPECTED_MACHINE)..."
  echo

  verify_machine_id
  verify_os
  prepare_ubuntu_repos
  ensure_nala
  install_docker_repo
  initial_update
  install_packages
  install_docker_engine

  # Recover the device's existing age identity before any host secrets are
  # decrypted. This is the linchpin for disaster recovery.
  setup_age_and_sops

  ensure_ssh_key
  install_starship
  set_user_environment_defaults

  # Machine-specific system configuration is intentionally delegated. For
  # vps01 this orchestrates the Wormlogic wg0 tunnel first, then the PVP stack.
  configure_host_system

  setup_package_export
  setup_system_update
  setup_git_monitoring
  setup_shared_monitoring
  prepare_shell_dotfiles
  apply_bash_stow
  apply_host_environment
  run_package_export
  show_summary
  prompt_reboot
}

main "$@"
