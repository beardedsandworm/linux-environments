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
# Ensure the multilib repository is enabled
# - required by Steam and Android SDK 32-bit dependencies
# --------------------------------------------------
enable_multilib() {
  echo "📦 Ensuring multilib repository is enabled..."

  if ! grep -qE '^[[:space:]]*#?[[:space:]]*\[multilib\][[:space:]]*$' /etc/pacman.conf; then
    echo "✗ [multilib] repository block not found in /etc/pacman.conf"
    exit 1
  fi

  sudo sed -i \
    '/^[[:space:]]*#\?[[:space:]]*\[multilib\][[:space:]]*$/,/^[[:space:]]*#\?[[:space:]]*Include[[:space:]]*=/ {
      s/^[[:space:]]*#[[:space:]]*\(\[multilib\]\)/\1/
      s/^[[:space:]]*#[[:space:]]*\(Include[[:space:]]*=\)/\1/
    }' \
    /etc/pacman.conf

  echo "✓ multilib repository enabled"
}

# --------------------------------------------------
# Verify repositories required by this workstation
# - core/extra are standard Arch repositories
# - multilib is required by Steam and Android tooling
# - AUR packages are handled by yay rather than an unofficial binary repo
# --------------------------------------------------
verify_required_repositories() {
  local repo
  local -a enabled_repos=()

  if ! command -v pacman-conf >/dev/null 2>&1; then
    echo "✗ pacman-conf not found"
    exit 1
  fi

  mapfile -t enabled_repos < <(pacman-conf --repo-list)

  for repo in core extra multilib; do
    if ! printf '%s\n' "${enabled_repos[@]}" | grep -qx "$repo"; then
      echo "✗ Required pacman repository is not enabled: $repo"
      exit 1
    fi
  done

  echo "✓ Required pacman repositories enabled: core, extra, multilib"

  for repo in "${enabled_repos[@]}"; do
    case "$repo" in
      core|extra|multilib) ;;
      *)
        echo "⚠ Additional pacman repository detected: $repo"
        echo "  This bootstrap does not create or configure that repository."
        ;;
    esac
  done
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
    sudo pacman -S --needed --noconfirm flatpak
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
# - pacman.txt: official Arch repositories only
# - yay.txt: AUR packages only
# - flatpak.txt: Flathub applications
# --------------------------------------------------
read_package_file() {
  local file="$1"
  grep -vE '^[[:space:]]*(#|$)' "$file" || true
}

install_packages() {
  local package_dir="$REPO_ROOT/system/$EXPECTED_MACHINE/$EXPECTED_OS"
  local pacman_file="$package_dir/pacman.txt"
  local yay_file="$package_dir/yay.txt"
  local flatpak_file="$package_dir/flatpak.txt"
  local -a packages=()
  local -a missing_official=()
  local -a now_official=()
  local pkg

  if [[ -f "$pacman_file" ]]; then
    mapfile -t packages < <(read_package_file "$pacman_file")
    if ((${#packages[@]} > 0)); then
      missing_official=()
      for pkg in "${packages[@]}"; do
        if ! pacman -Si -- "$pkg" >/dev/null 2>&1; then
          missing_official+=("$pkg")
        fi
      done

      if ((${#missing_official[@]} > 0)); then
        echo "✗ pacman.txt contains package(s) not found in enabled official repositories:"
        printf '  %s\n' "${missing_official[@]}"
        echo "  Move current AUR packages to yay.txt or restore a genuinely required repository."
        exit 1
      fi

      echo "📦 Installing official Arch packages from $pacman_file..."
      sudo pacman -S --needed --noconfirm "${packages[@]}"
    else
      echo "⚠ pacman.txt contains no packages, skipping"
    fi
  else
    echo "⚠ No pacman.txt found at $pacman_file, skipping"
  fi

  # yay itself is bootstrapped explicitly and is not listed in yay.txt.
  ensure_yay

  packages=()
  if [[ -f "$yay_file" ]]; then
    mapfile -t packages < <(read_package_file "$yay_file")
    if ((${#packages[@]} > 0)); then
      now_official=()
      for pkg in "${packages[@]}"; do
        if pacman -Si -- "$pkg" >/dev/null 2>&1; then
          now_official+=("$pkg")
        fi
      done

      if ((${#now_official[@]} > 0)); then
        echo "⚠ yay.txt contains package(s) now available from official repositories:"
        printf '  %s\n' "${now_official[@]}"
        echo "  yay can still install them, but move them to pacman.txt during the next cleanup."
      fi

      echo "📦 Installing AUR packages from $yay_file..."
      yay -S --needed --noconfirm "${packages[@]}"
    else
      echo "⚠ yay.txt contains no active packages, skipping"
    fi
  else
    echo "⚠ No yay.txt found at $yay_file, skipping AUR packages"
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
  else
    echo "⚠ No flatpak.txt found at $flatpak_file, skipping"
  fi
}

# --------------------------------------------------
# Credential recovery helpers
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

  echo "🔐 Installing sops from the official Arch repositories..."
  sudo pacman -S --needed --noconfirm sops
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
    echo "  Ensure 'age' is present in system/$EXPECTED_MACHINE/$EXPECTED_OS/pacman.txt"
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
# - complete encrypted *.conf files are the recovery artifacts
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
  local wireguard_sudoers_script="$REPO_ROOT/scripts/install-wireguard-sudoers.sh"

  echo "⚙ Configuring system..."

  if [[ ! -x "$wireguard_sudoers_script" ]]; then
    echo "✗ Missing or non-executable system configuration helper:"
    echo "  $wireguard_sudoers_script"
    exit 1
  fi

  "$wireguard_sudoers_script"
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
# - roaming client routes the VPN subnet and home LAN through Heighliner/Midway
# - consumes the recovered full config only as the identity source
# - captures the final live config after applying current bootstrap settings
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
  local vpn_allowed_ips="10.8.0.0/24, 10.42.42.0/24"
  local vpn_dns_server="10.42.42.1"
  local vpn_dns_domain="~wormlogic.com"
  local default_vpn_ip="10.8.0.10/32"

  local machine_id
  local local_dir
  local credential_dir
  local staged_conf
  local staged_public
  local local_public_file
  local source_conf
  local target_conf
  local settings_file
  local server_pubkey_file
  local capture_script
  local restore_script

  local client_private_key
  local client_vpn_ip
  local vps_public_key
  local input_vpn_ip

  echo "🔐 Setting up Wormlogic WireGuard client..."

  machine_id="$(tr -d '\r\n' < "$MACHINE_ID_FILE")"

  local_dir="$REPO_ROOT/local/wireguard"
  credential_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/wireguard"
  staged_conf="$credential_dir/${vpn_name}.conf"
  staged_public="$credential_dir/${vpn_name}.public-key"
  local_public_file="$local_dir/${machine_id}.pub"
  source_conf="$local_dir/$vpn_name.conf"
  target_conf="/etc/wireguard/$vpn_name.conf"
  settings_file="$local_dir/$vpn_name.env"
  server_pubkey_file="$REPO_ROOT/shared/wireguard/wormlogic-server.pub"
  capture_script="$REPO_ROOT/scripts/capture-wireguard-credentials.sh"
  restore_script="$REPO_ROOT/scripts/restore-wireguard-credentials.sh"

  require_credential_script "$capture_script"
  require_credential_script "$restore_script"

  mkdir -p "$local_dir" "$credential_dir" "$(dirname "$server_pubkey_file")"
  chmod 700 "$REPO_ROOT/local" "$local_dir" "$credential_dir"

  if [[ -f "$staged_conf" ]]; then
    client_private_key="$(read_wireguard_private_key "$staged_conf")"
    if [[ -z "$client_private_key" ]]; then
      echo "✗ Recovered WireGuard config has no PrivateKey: $staged_conf"
      exit 1
    fi
  elif [[ "${WIREGUARD_GENERATE_NEW:-0}" -eq 1 ]]; then
    echo "• Generating new WireGuard identity for $machine_id..."
    client_private_key="$(wg genkey)"
  else
    echo "✗ Reconciled WireGuard config is missing: $staged_conf"
    exit 1
  fi

  if ! printf '%s\n' "$client_private_key" | wg pubkey >/dev/null 2>&1; then
    echo "✗ Wormlogic PrivateKey is invalid"
    exit 1
  fi

  if [[ -f "$settings_file" ]]; then
    # shellcheck disable=SC1090
    source "$settings_file"
  fi

  if [[ -f "$server_pubkey_file" ]]; then
    vps_public_key="$(tr -d '[:space:]' < "$server_pubkey_file")"
  fi

  if [[ -z "${vps_public_key:-}" ]]; then
    echo
    echo "Missing Wormlogic VPS WireGuard public key."
    echo "Get it with:"
    echo "  ssh lightweight@vpn.wormlogic.com 'sudo wg show wg0 public-key'"
    echo
    read -r -p "VPS WireGuard public key: " vps_public_key

    if [[ -z "$vps_public_key" ]]; then
      echo "✗ VPS public key cannot be empty"
      exit 1
    fi

    printf '%s\n' "$vps_public_key" > "$server_pubkey_file"
    chmod 644 "$server_pubkey_file"

    echo "✓ Saved VPS public key to $server_pubkey_file"
    echo "  Commit this file so future bootstraps do not prompt again."
  fi

  if ! printf '%s\n' "$vps_public_key" | wg pubkey >/dev/null 2>&1; then
    echo "✗ Invalid VPS public key"
    exit 1
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
  } > "$settings_file"
  chmod 600 "$settings_file"

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
  } > "$source_conf"
  chmod 600 "$source_conf"

  echo "• Installing WireGuard config: $target_conf"
  sudo install -d -m 700 /etc/wireguard
  sudo install -m 600 "$source_conf" "$target_conf"

  # The final live config contains the selected identity plus today's
  # authoritative routing/peer settings. Capture that complete file, then
  # refresh staging and derive the public key via the restore helper.
  bash "$capture_script" --force
  bash "$restore_script" --force

  if [[ ! -f "$staged_public" ]]; then
    echo "✗ WireGuard restore did not produce the expected public key:"
    echo "  $staged_public"
    exit 1
  fi

  install -m 0644 "$staged_public" "$local_public_file"

  sudo systemctl enable --now "wg-quick@$vpn_name"

  if command -v resolvectl >/dev/null 2>&1; then
    sudo resolvectl dns "$vpn_name" "$vpn_dns_server" || true
    sudo resolvectl domain "$vpn_name" "$vpn_dns_domain" || true
    sudo resolvectl default-route "$vpn_name" yes || true
  fi

  WORMLOGIC_VPN_MACHINE_ID="$machine_id"
  WORMLOGIC_VPN_PUBLIC_KEY="$(tr -d '\r\n' < "$staged_public")"
  WORMLOGIC_VPN_IP="$client_vpn_ip"

  echo "✓ Wormlogic VPN configured"
}

# --------------------------------------------------
# Setup PVP WireGuard client
# - full-tunnel privacy path through Heighliner -> Proton
# - consumes recovered wg-pvp.conf as the identity source when available
# - captures the final full config into the normal WireGuard recovery set
# - installs the wg-quick configuration but leaves the service disabled
# --------------------------------------------------
setup_pvp_vpn() {
  local vpn_name="wg-pvp"
  local vps_host="vpn.wormlogic.com"
  local vpn_allowed_ips="0.0.0.0/0"
  local default_vpn_ip="10.9.0.10/32"

  local machine_id
  local local_dir
  local credential_dir
  local staged_conf
  local staged_public
  local local_public_file
  local source_conf
  local target_conf
  local settings_file
  local server_pubkey_file
  local capture_script
  local restore_script

  local client_private_key
  local client_vpn_ip
  local vps_public_key
  local input_vpn_ip

  echo "🔐 Setting up PVP WireGuard client..."

  machine_id="$(tr -d '\r\n' < "$MACHINE_ID_FILE")"

  local_dir="$REPO_ROOT/local/wireguard"
  credential_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/wireguard"
  staged_conf="$credential_dir/${vpn_name}.conf"
  staged_public="$credential_dir/${vpn_name}.public-key"
  local_public_file="$local_dir/${machine_id}-pvp.pub"
  source_conf="$local_dir/${vpn_name}.conf"
  target_conf="/etc/wireguard/${vpn_name}.conf"
  settings_file="$local_dir/${vpn_name}.env"
  server_pubkey_file="$REPO_ROOT/system/vps01/ubuntu/pvp/heighliner.pub"
  capture_script="$REPO_ROOT/scripts/capture-wireguard-credentials.sh"
  restore_script="$REPO_ROOT/scripts/restore-wireguard-credentials.sh"

  require_credential_script "$capture_script"
  require_credential_script "$restore_script"

  mkdir -p "$local_dir" "$credential_dir" "$(dirname "$server_pubkey_file")"
  chmod 700 "$REPO_ROOT/local" "$local_dir" "$credential_dir"

  if [[ -f "$staged_conf" ]]; then
    client_private_key="$(read_wireguard_private_key "$staged_conf")"
    if [[ -z "$client_private_key" ]]; then
      echo "✗ Recovered PVP WireGuard config has no PrivateKey: $staged_conf"
      exit 1
    fi
  else
    echo "• No recovered PVP identity found; generating a new identity for $machine_id..."
    client_private_key="$(wg genkey)"
  fi

  if ! printf '%s\n' "$client_private_key" | wg pubkey >/dev/null 2>&1; then
    echo "✗ PVP PrivateKey is invalid"
    exit 1
  fi

  if [[ -f "$settings_file" ]]; then
    # shellcheck disable=SC1090
    source "$settings_file"
  fi

  if [[ -f "$server_pubkey_file" ]]; then
    vps_public_key="$(tr -d '[:space:]' < "$server_pubkey_file")"
  fi

  if [[ -z "${vps_public_key:-}" ]]; then
    echo
    echo "Missing Heighliner PVP WireGuard public key."
    echo "Get it with:"
    echo "  ssh heighliner 'sudo wg show wg-pvp public-key'"
    echo
    read -r -p "Heighliner PVP public key: " vps_public_key

    if [[ -z "$vps_public_key" ]]; then
      echo "✗ Heighliner PVP public key cannot be empty"
      exit 1
    fi

    printf '%s\n' "$vps_public_key" > "$server_pubkey_file"
    chmod 644 "$server_pubkey_file"

    echo "✓ Saved Heighliner PVP public key to $server_pubkey_file"
    echo "  Commit this file so future bootstraps do not prompt again."
  fi

  if ! printf '%s\n' "$vps_public_key" | wg pubkey >/dev/null 2>&1; then
    echo "✗ Invalid Heighliner PVP public key"
    exit 1
  fi

  if [[ -z "${PVP_VPN_IP:-}" ]]; then
    echo
    read -r -p "Laptop PVP IP [$default_vpn_ip]: " input_vpn_ip
    PVP_VPN_IP="${input_vpn_ip:-$default_vpn_ip}"
  fi

  client_vpn_ip="$PVP_VPN_IP"

  if [[ ! "$client_vpn_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    echo "✗ Invalid PVP client IP/CIDR: $client_vpn_ip"
    exit 1
  fi

  {
    echo "PVP_VPN_IP='$client_vpn_ip'"
    echo "PVP_ALLOWED_IPS='$vpn_allowed_ips'"
  } > "$settings_file"
  chmod 600 "$settings_file"

  echo "• Writing local PVP WireGuard config: $source_conf"
  {
    echo "[Interface]"
    echo "PrivateKey = $client_private_key"
    echo "Address = $client_vpn_ip"
    echo
    echo "[Peer]"
    echo "PublicKey = $vps_public_key"
    echo "Endpoint = $vps_host:51821"
    echo "AllowedIPs = $vpn_allowed_ips"
    echo "PersistentKeepalive = 25"
  } > "$source_conf"
  chmod 600 "$source_conf"

  echo "• Installing PVP WireGuard config: $target_conf"
  sudo install -d -m 700 /etc/wireguard
  sudo install -m 600 "$source_conf" "$target_conf"

  # Capture the completed PVP config together with the machine's other
  # WireGuard configs, then refresh staging and derive the public key.
  bash "$capture_script" --force
  bash "$restore_script" --force

  if [[ ! -f "$staged_public" ]]; then
    echo "✗ WireGuard restore did not produce the expected PVP public key:"
    echo "  $staged_public"
    exit 1
  fi

  install -m 0644 "$staged_public" "$local_public_file"

  # PVP is intentionally opt-in. The wg-quick unit remains available for the
  # pvp-up/pvp-down/pvp-toggle helpers, but it must not start automatically.
  sudo systemctl disable "wg-quick@$vpn_name" >/dev/null 2>&1 || true

  if systemctl is-active --quiet "wg-quick@$vpn_name"; then
    echo "⚠ wg-quick@$vpn_name is currently active; leaving the live session alone."
    echo "  It is disabled for future boots and pvp-down can stop it when desired."
  fi

  PVP_VPN_MACHINE_ID="$machine_id"
  PVP_VPN_PUBLIC_KEY="$(tr -d '\r\n' < "$staged_public")"
  PVP_VPN_IP="$client_vpn_ip"

  echo "✓ PVP VPN configured"
  echo "  wg-quick@$vpn_name is disabled and was not started."
}

# --------------------------------------------------
# Configure automatic VPN selection
# - home networks: disable both tunnels
# - trusted networks: enable Wormlogic split tunnel
# - unknown networks: enable PVP privacy tunnel
# - setup is idempotent and manages the user services,
#   trust registry, and required privileged integration
# --------------------------------------------------
setup_vpn_automation() {
  local setup_script="$REPO_ROOT/system/$EXPECTED_MACHINE/$EXPECTED_OS/vpn-auto/setup.sh"

  echo "🔐 Configuring automatic VPN selection..."

  if [[ ! -x "$setup_script" ]]; then
    echo "⚠ VPN automation setup not found or not executable:"
    echo "  $setup_script"
    return 0
  fi

  "$setup_script"

  echo "✓ Automatic VPN selection configured"
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
  echo "SOPS age identity:"
  echo "  Public key: ${AGE_PUBLIC_KEY:-unavailable}"
  echo "  Recovery:   ${AGE_RECOVERY_FILE:-unavailable}"
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

  echo "WireGuard (PVP):"

  if [[ -n "${PVP_VPN_PUBLIC_KEY:-}" ]]; then
    echo "  Interface: wg-pvp"
    echo "  PVP IP:    ${PVP_VPN_IP:-unknown}"
    echo "  Service:   disabled / manual activation"
    echo
    echo "⚠ Action required on Heighliner:"
    echo
    echo "Add this peer under system/vps01/ubuntu/pvp/peers/:"
    echo
    echo "  # ${PVP_VPN_MACHINE_ID:-unknown}"
    echo "  [Peer]"
    echo "  PublicKey = $PVP_VPN_PUBLIC_KEY"
    echo "  AllowedIPs = ${PVP_VPN_IP:-REPLACE_WITH_CLIENT_IP}"
    echo
    echo "Then rerun Heighliner's PVP setup or reload the wg-pvp peer configuration."
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
  verify_required_repositories
  initial_update
  install_packages

  # Credential recovery happens after required packages are present and before
  # services/configuration consume those credentials.
  setup_age_and_sops
  reconcile_ssh_credentials
  reconcile_wireguard_credentials

  set_user_environment_defaults
  configure_system
  setup_package_export
  setup_credential_capture
  setup_system_update
  setup_git_monitoring
  setup_shared_monitoring
  setup_timeshift_snapshot
  setup_wormlogic_vpn
  setup_pvp_vpn
  setup_vpn_automation
  prepare_shell_dotfiles
  apply_general_dotfiles
  apply_host_environment
  run_package_export
  show_summary

  echo
  echo "📊 Services configured:"
  echo "   - package-export        → state tracking (runs now + daily)"
  if [[ "${CREDENTIAL_CAPTURE_CONFIGURED:-0}" -eq 1 ]]; then
    echo "   - credential-capture    → encrypted credential recovery capture"
  else
    echo "   - credential-capture    → pending unit files"
  fi
  echo "   - system-update         → system maintenance (scheduled)"
  echo "   - repo-update-check     → remote update awareness (daily)"
  echo "   - dotfiles-change-check → local dotfiles drift awareness (daily)"
  echo "   - disk-space-check      → local disk usage warning (daily)"
  echo "   - heartbeat             → device online signal (daily)"
  echo "   - timeshift-snapshot    → weekly rollback snapshot"
  echo "   - wormlogic-vpn         → WireGuard tunnel to vpn.wormlogic.com"
  echo "   - pvp-vpn               → privacy tunnel (manual activation only)"
  echo

  prompt_reboot
}

main "$@"
