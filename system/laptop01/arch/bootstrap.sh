#!/usr/bin/env bash

set -euo pipefail

# --------------------------------------------------
# Resolve repo root and machine identity file path
# --------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MACHINE_ID_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id"
EXPECTED_MACHINE="${1:-laptop01}"
EXPECTED_OS="arch"
MACHINE_LABEL="Dell Precision"

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
  if ! command -v pacman >/dev/null 2>&1; then
    echo "✗ Arch bootstrap called on non-Arch system"
    exit 1
  fi

  echo "✓ Operating system verified: $EXPECTED_OS"
}

# --------------------------------------------------
# Enable multilib repository in pacman.conf
# --------------------------------------------------
enable_multilib() {
  echo "📦 Enabling multilib repository..."
  sudo sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
}

# --------------------------------------------------
# Perform initial system update
# --------------------------------------------------
initial_update() {
  echo "🔄 Performing initial system update..."
  sudo pacman -Syu --noconfirm
}

# --------------------------------------------------
# Ensure yay is available
# --------------------------------------------------
ensure_yay() {
  if command -v yay >/dev/null 2>&1; then
    echo "✓ yay is available"
    return 0
  fi

  echo "📦 yay not found. Installing yay..."
  sudo pacman -S --needed --noconfirm base-devel git

  local tmpdir
  tmpdir="$(mktemp -d)"
  git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
  pushd "$tmpdir/yay" >/dev/null
  makepkg -si --noconfirm
  popd >/dev/null
  rm -rf "$tmpdir"

  echo "✓ yay installed"
}

# --------------------------------------------------
# Install Flatpak and configure Flathub if needed
# --------------------------------------------------
ensure_flatpak() {
  if ! command -v flatpak >/dev/null 2>&1; then
    echo "📦 flatpak not found. Installing flatpak..."
    yay -S --needed --noconfirm flatpak
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
# Install packages from machine-specific lists
# --------------------------------------------------
install_packages() {
  local package_dir="$REPO_ROOT/system/$EXPECTED_MACHINE/$EXPECTED_OS"
  local pacman_file="$package_dir/pacman.txt"
  local flatpak_file="$package_dir/flatpak.txt"

  if [[ -f "$pacman_file" ]]; then
    echo "📦 Installing packages from $pacman_file..."
    mapfile -t pacman_packages <"$pacman_file"
    if ((${#pacman_packages[@]} > 0)); then
      yay -S --needed --noconfirm "${pacman_packages[@]}"
    else
      echo "⚠ pacman.txt exists but is empty, skipping"
    fi
  else
    echo "⚠ No pacman.txt found at $pacman_file, skipping"
  fi

  if [[ -f "$flatpak_file" ]]; then
    ensure_flatpak
    echo "📦 Installing Flatpak packages from $flatpak_file..."
    mapfile -t flatpak_packages <"$flatpak_file"
    if ((${#flatpak_packages[@]} > 0)); then
      for pkg in "${flatpak_packages[@]}"; do
        flatpak install -y flathub "$pkg"
      done
    else
      echo "⚠ flatpak.txt exists but is empty, skipping"
    fi
  else
    echo "⚠ No flatpak.txt found at $flatpak_file, skipping"
  fi
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
# Install Nerd Font: FiraCode
# --------------------------------------------------
install_nerd_font() {
  local tmpdir

  echo "🔤 Installing Nerd Font: FiraCode..."

  if command -v fc-list >/dev/null 2>&1 && fc-list | grep -qi "FiraCode Nerd Font"; then
    echo "✓ FiraCode Nerd Font already installed"
    return 0
  fi

  tmpdir="$(mktemp -d)"
  git clone --depth 1 https://github.com/ryanoasis/nerd-fonts.git "$tmpdir/nerd-fonts"
  pushd "$tmpdir/nerd-fonts" >/dev/null
  ./install.sh FiraCode
  popd >/dev/null
  rm -rf "$tmpdir"

  if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -fv >/dev/null 2>&1 || true
  fi

  echo "✓ FiraCode Nerd Font installed"
}

# --------------------------------------------------
# Set default user environment
# - PATH
# - editor / terminal
# - file manager / browser / mail client
# --------------------------------------------------
set_user_environment_defaults() {
  echo "🌱 Setting user environment defaults..."

  mkdir -p "$HOME/.config/environment.d"
  mkdir -p "$HOME/.local/bin"

  cat >"$HOME/.config/environment.d/path.conf" <<EOF
PATH=$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
EOF

  cat >"$HOME/.config/environment.d/defaults.conf" <<EOF
EDITOR=nvim
VISUAL=nvim
TERMINAL=alacritty
EOF

  if command -v alacritty >/dev/null 2>&1; then
    cat >"$HOME/.local/bin/xdg-terminal-exec" <<'EOF'
#!/usr/bin/env bash
exec alacritty "$@"
EOF
    chmod +x "$HOME/.local/bin/xdg-terminal-exec"
    echo "✓ xdg-terminal-exec configured"
  else
    echo "⚠ alacritty not found, skipping terminal binding"
  fi

  if command -v nvim >/dev/null 2>&1; then
    git config --global core.editor "nvim"
    git config --global sequence.editor "nvim"
    echo "✓ Git editor set to nvim"
  else
    echo "⚠ nvim not found, skipping git editor config"
  fi

  if command -v xdg-mime >/dev/null 2>&1 && command -v xdg-settings >/dev/null 2>&1; then
    if [[ -f /usr/share/applications/org.kde.dolphin.desktop ]]; then
      xdg-mime default org.kde.dolphin.desktop inode/directory
      echo "✓ Default file manager set to Dolphin"
    else
      echo "⚠ Dolphin desktop entry not found, skipping file manager default"
    fi

    if [[ -f /usr/share/applications/firefox.desktop ]]; then
      xdg-settings set default-web-browser firefox.desktop || true
      xdg-mime default firefox.desktop x-scheme-handler/http
      xdg-mime default firefox.desktop x-scheme-handler/https
      xdg-mime default firefox.desktop text/html
      echo "✓ Default browser set to Firefox"
    else
      echo "⚠ Firefox desktop entry not found, skipping browser default"
    fi

    if [[ -f /usr/share/applications/thunderbird.desktop ]]; then
      xdg-mime default thunderbird.desktop x-scheme-handler/mailto
      xdg-mime default thunderbird.desktop message/rfc822
      echo "✓ Default mail client set to Thunderbird"
    else
      echo "⚠ Thunderbird desktop entry not found, skipping mail client default"
    fi
  else
    echo "⚠ xdg tools not found, skipping default app associations"
  fi

  echo "✓ Environment defaults configured"
}

# --------------------------------------------------
# Install System Configurations
# --------------------------------------------------
configure_system() {
    echo "⚙ Configuring system..."
    "$REPO_ROOT/scripts/install-wireguard-sudoers.sh"
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
# Install and enable shared monitoring services/timers
# - disk-space-check
# - heartbeat
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
# Install and enable Timeshift snapshot service/timer
# - Arch workstations only
# --------------------------------------------------
setup_timeshift_snapshot() {
  echo "⚙ Setting up Timeshift snapshot service and timer..."

  mkdir -p "$HOME/.config/systemd/user"

  cp "$REPO_ROOT/systemd/timeshift-snapshot.service" "$HOME/.config/systemd/user/"
  cp "$REPO_ROOT/systemd/timeshift-snapshot.timer" "$HOME/.config/systemd/user/"

  systemctl --user daemon-reload
  systemctl --user enable --now timeshift-snapshot.timer

  echo "✓ Timeshift snapshot timer enabled"
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
# Setup Wormlogic WireGuard client
# --------------------------------------------------
setup_wormlogic_vpn() {
  local vpn_name="wormlogic"
  local vps_host="vpn.wormlogic.com"
  local vpn_allowed_ips="10.8.0.0/24, 10.42.42.0/24"
  local vpn_dns_server="10.42.42.1"
  local vpn_dns_domain="~wormlogic.com"
  local default_vpn_ip="10.8.0.10/32"

  local machine_id_file="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id"
  local machine_id
  local local_dir
  local private_key_file
  local public_key_file
  local source_conf
  local target_conf
  local settings_file
  local server_pubkey_file
  local client_private_key
  local client_vpn_ip
  local vps_public_key
  local input_vpn_ip

  echo " Setting up Wormlogic WireGuard client..."

  if [[ ! -f "$machine_id_file" ]]; then
    echo "✗ Missing machine-id file: $machine_id_file"
    exit 1
  fi

  machine_id="$(<"$machine_id_file")"

  local_dir="$REPO_ROOT/local/wireguard"
  private_key_file="$local_dir/${machine_id}.key"
  public_key_file="$local_dir/${machine_id}.pub"
  source_conf="$local_dir/$vpn_name.conf"
  target_conf="/etc/wireguard/$vpn_name.conf"
  settings_file="$local_dir/$vpn_name.env"
  server_pubkey_file="$REPO_ROOT/shared/wireguard/wormlogic-server.pub"

  if ! command -v wg >/dev/null 2>&1; then
    echo "✗ wg not found. wireguard-tools must be installed first."
    exit 1
  fi

  mkdir -p "$local_dir"
  mkdir -p "$(dirname "$server_pubkey_file")"
  chmod 700 "$REPO_ROOT/local" "$local_dir"

  if [[ ! -f "$private_key_file" ]]; then
    echo "• Generating WireGuard key for $machine_id..."
    wg genkey | tee "$private_key_file" | wg pubkey >"$public_key_file"
    chmod 600 "$private_key_file"
    chmod 644 "$public_key_file"
  else
    echo "✓ Existing WireGuard key found for $machine_id"
    if [[ ! -f "$public_key_file" ]]; then
      wg pubkey <"$private_key_file" >"$public_key_file"
      chmod 644 "$public_key_file"
    fi
  fi

  if [[ -f "$settings_file" ]]; then
    # shellcheck disable=SC1090
    source "$settings_file"
  fi

  if [[ -f "$server_pubkey_file" ]]; then
    vps_public_key="$(tr -d '[:space:]' <"$server_pubkey_file")"
  fi

  if [[ -z "${vps_public_key:-}" ]]; then
    echo
    echo "Missing Wormlogic VPS WireGuard public key."
    echo "Get it with:"
    echo "  ssh lightweight@vpn.wormlogic.com 'sudo cat /etc/wireguard/publickey'"
    echo
    read -r -p "VPS WireGuard public key: " vps_public_key

    if [[ -z "$vps_public_key" ]]; then
      echo "✗ VPS public key cannot be empty"
      exit 1
    fi

    printf '%s\n' "$vps_public_key" >"$server_pubkey_file"
    chmod 644 "$server_pubkey_file"

    echo "✓ Saved VPS public key to $server_pubkey_file"
    echo "  Commit this file so future bootstraps do not prompt again."
  fi

  if [[ -z "${WORMLOGIC_VPN_IP:-}" ]]; then
    echo
    read -r -p "Laptop VPN IP [$default_vpn_ip]: " input_vpn_ip
    WORMLOGIC_VPN_IP="${input_vpn_ip:-$default_vpn_ip}"
  fi

  client_vpn_ip="$WORMLOGIC_VPN_IP"

  if [[ ! "$client_vpn_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    echo "✗ Invalid client VPN IP/CIDR: $client_vpn_ip"
    exit 1
  fi

  {
    echo "WORMLOGIC_VPN_IP='$client_vpn_ip'"
    echo "WORMLOGIC_ALLOWED_IPS='$vpn_allowed_ips'"
    echo "WORMLOGIC_DNS_SERVER='$vpn_dns_server'"
    echo "WORMLOGIC_DNS_DOMAIN='$vpn_dns_domain'"
  } >"$settings_file"
  chmod 600 "$settings_file"

  client_private_key="$(<"$private_key_file")"

  echo "• Writing local WireGuard config: $source_conf"

  {
    echo "[Interface]"
    echo "PrivateKey = $client_private_key"
    echo "Address = $client_vpn_ip"
    echo
    echo "[Peer]"
    echo "PublicKey = $vps_public_key"
    echo "Endpoint = $vps_host:51820"
    echo "AllowedIPs = $vpn_allowed_ips"
    echo "PersistentKeepalive = 25"
  } >"$source_conf"

  chmod 600 "$source_conf"

  echo "• Installing WireGuard config: $target_conf"

  sudo install -d -m 700 /etc/wireguard
  sudo install -m 600 "$source_conf" "$target_conf"
  sudo systemctl enable --now "wg-quick@$vpn_name"

  if command -v resolvectl >/dev/null 2>&1; then
    sudo resolvectl dns "$vpn_name" "$vpn_dns_server" || true
    sudo resolvectl domain "$vpn_name" "$vpn_dns_domain" || true
    sudo resolvectl default-route "$vpn_name" yes || true
  fi

  WORMLOGIC_VPN_MACHINE_ID="$machine_id"
  WORMLOGIC_VPN_PUBLIC_KEY="$(<"$public_key_file")"
  WORMLOGIC_VPN_IP="$client_vpn_ip"

  echo "✓ Wormlogic VPN configured"
}

# --------------------------------------------------
# Prepare shell dotfiles for stow
# - back up regular files
# - leave symlinks alone
# --------------------------------------------------
prepare_shell_dotfiles() {
  local backup_dir="$HOME/.dotfile-backups/$(date +%Y%m%d-%H%M%S)"
  local files=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_logout")

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
# Apply general dotfiles via stow
# --------------------------------------------------
apply_general_dotfiles() {
  echo "🔗 Applying general dotfiles..."
  "$REPO_ROOT/scripts/stow-all.sh"
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
  echo "📝 Exporting current package state..."
  "$REPO_ROOT/scripts/package-export.sh"
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

  if command -v fastfetch >/dev/null 2>&1; then
    fastfetch
    echo
  fi

  echo "Git user:"
  echo "  Name:  $git_name"
  echo "  Email: $git_email"
  echo
  echo "Local IP:"
  echo "  $local_ip"
  echo
  echo "WireGuard (Wormlogic VPN):"

  if [[ -n "${WORMLOGIC_VPN_PUBLIC_KEY:-}" ]]; then
    echo "  Interface: wormlogic"
    echo "  VPN IP:    ${WORMLOGIC_VPN_IP:-unknown}"
    echo
    echo "⚠ Action required on VPS:"
    echo
    echo "Add this peer to /etc/wireguard/wg0.conf:"
    echo
    echo "  # ${WORMLOGIC_VPN_MACHINE_ID:-unknown}"
    echo "  [Peer]"
    echo "  PublicKey = $WORMLOGIC_VPN_PUBLIC_KEY"
    echo "  AllowedIPs = ${WORMLOGIC_VPN_IP:-REPLACE_WITH_CLIENT_IP}"
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
  enable_multilib
  initial_update
  ensure_yay
  install_packages
  install_starship
  install_nerd_font
  set_user_environment_defaults
  configure_system
  setup_package_export
  setup_system_update
  setup_git_monitoring
  setup_shared_monitoring
  setup_timeshift_snapshot
  setup_wormlogic_vpn
  prepare_shell_dotfiles
  apply_general_dotfiles
  apply_host_environment
  run_package_export
  show_summary

  echo
  echo "📊 Services configured:"
  echo "   - package-export        → state tracking (runs now + daily)"
  echo "   - system-update         → system maintenance (scheduled)"
  echo "   - repo-update-check     → remote update awareness (daily)"
  echo "   - dotfiles-change-check → local dotfiles drift awareness (daily)"
  echo "   - disk-space-check      → local disk usage warning (daily)"
  echo "   - heartbeat             → device online signal (daily)"
  echo "   - timeshift-snapshot    → weekly rollback snapshot"
  echo "   - wormlogic-vpn         → WireGuard tunnel to vpn.wormlogic.com"
  echo

  prompt_reboot
}

main "$@"
