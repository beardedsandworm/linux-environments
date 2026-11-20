#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MACHINE_ID_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id"

EXPECTED_MACHINE="${1:-vps02}"
EXPECTED_OS="ubuntu"
MACHINE_LABEL="Farcaster VPS"

# --------------------------------------------------
# Bootstrap safety and identity validation
# - run as the normal user; sudo is used only where required
# - verify the declared machine ID and Ubuntu platform before changes
# --------------------------------------------------
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

# --------------------------------------------------
# Prepare Ubuntu repositories and package tooling
# - enable standard Ubuntu supplemental repositories
# - ensure nala is available
# - configure Docker's upstream apt repository
# --------------------------------------------------
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

# --------------------------------------------------
# Update the base system and install declared host packages
# - apt.txt is the authoritative Ubuntu package list for this host
# --------------------------------------------------
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

# --------------------------------------------------
# Install and enable Docker Engine
# - use Docker's upstream packages and Compose plugin
# - add the normal user to the docker group
# --------------------------------------------------
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
# Reconcile the host SOPS/age identity
# - restore or capture the durable age recovery identity first
# - refuse to generate a replacement when encrypted host secrets exist
# - ensure sops is available only after the age identity is settled
# --------------------------------------------------
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
      jq -r '.tag_name'
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
  local key_file="${SOPS_AGE_KEY_FILE:-$age_dir/keys.txt}"
  local key_dir
  local dotfiles_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles"
  local public_key_file="$dotfiles_dir/age-public-key"
  local machine_id host_secret_dir recovery_file
  local capture_script restore_script public_key backup_file
  local local_exists=0 repo_exists=0

  echo "🔐 Reconciling SOPS age identity..."

  if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
    echo "✗ age/age-keygen not found. Ensure 'age' is installed by apt.txt."
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
# - preserve the device identity at ~/.ssh/id_ed25519
# - ensure a repo-specific GitHub deploy identity for linux-environments
# - public keys are regenerated by restore-ssh-credentials.sh
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
  local device_key="$ssh_dir/id_ed25519"
  local device_pub="${device_key}.pub"
  local deploy_key="$ssh_dir/id_ed25519_git_linux-environments"
  local deploy_pub="${deploy_key}.pub"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  # Preserve the normal device identity used to SSH into the lab.
  if [[ ! -f "$device_key" ]]; then
    echo "• Generating missing device SSH identity..."
    ssh-keygen -t ed25519 \
      -f "$device_key" \
      -N "" \
      -C "$EXPECTED_MACHINE:device"
  fi

  chmod 600 "$device_key"

  if [[ ! -f "$device_pub" ]]; then
    ssh-keygen -y -f "$device_key" > "$device_pub"
  fi
  chmod 644 "$device_pub"

  # linux-environments gets its own GitHub deploy key rather than reusing the
  # machine's shell/login identity.
  if [[ ! -f "$deploy_key" ]]; then
    echo "• Generating linux-environments GitHub deploy key..."
    ssh-keygen -t ed25519 \
      -f "$deploy_key" \
      -N "" \
      -C "$EXPECTED_MACHINE:github:linux-environments"
  fi

  chmod 600 "$deploy_key"

  if [[ ! -f "$deploy_pub" ]]; then
    ssh-keygen -y -f "$deploy_key" > "$deploy_pub"
  fi
  chmod 644 "$deploy_pub"

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
      echo "• Local SSH credentials selected as authoritative"
    else
      echo "• Repository SSH credentials selected as authoritative"
      bash "$restore_script" --force
    fi
  elif (( local_exists )); then
    echo "✓ Local SSH credentials found; no repository copy exists"
  elif (( repo_exists )); then
    echo "✓ Repository SSH credentials found; restoring them"
    bash "$restore_script" --force
  else
    echo "• No local or repository SSH credentials found; generating them..."
  fi

  # Reconciliation may restore an older credential set that predates repo-
  # specific deploy keys. Ensure the complete current identity set exists,
  # then immediately recapture it so recovery state is authoritative.
  ensure_local_ssh_credentials
  bash "$capture_script" --force

  echo "✓ SSH credentials ready"
}

configure_linux_environments_git_access() {
  local deploy_key="$HOME/.ssh/id_ed25519_git_linux-environments"
  local origin=""

  if [[ ! -f "$deploy_key" ]]; then
    echo "✗ linux-environments deploy key is missing: $deploy_key"
    exit 1
  fi

  origin="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"

  if [[ "$origin" =~ ^https://github\.com/(.+)$ ]]; then
    origin="git@github.com:${BASH_REMATCH[1]}"
    git -C "$REPO_ROOT" remote set-url origin "$origin"
    echo "✓ Converted linux-environments origin to SSH"
  elif [[ -n "$origin" ]]; then
    echo "✓ linux-environments origin already configured: $origin"
  else
    echo "⚠ linux-environments has no origin remote configured"
  fi

  git -C "$REPO_ROOT" config core.sshCommand \
    "ssh -i $deploy_key -o IdentitiesOnly=yes"

  echo "✓ linux-environments is bound to its repo-specific deploy key"
}

# --------------------------------------------------
# Reconcile the standard Wormlogic client, matching the other hosts.
# First rerun accepts the older vps02 wg0 stub as an identity source.
# New installs generate the real wormlogic.conf directly in setup.
# --------------------------------------------------
reconcile_wireguard_credentials() {
  local machine_id wireguard_secret_dir capture_script restore_script staged_dir
  local local_exists=0 repo_exists=0

  echo "🔐 Reconciling WireGuard credentials..."
  command -v wg >/dev/null 2>&1 || {
    echo "✗ wg not found. Install wireguard-tools first." >&2
    exit 1
  }

  machine_id="$(tr -d '\r\n' < "$MACHINE_ID_FILE")"
  wireguard_secret_dir="$REPO_ROOT/secrets/$machine_id/wireguard"
  staged_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/wireguard"
  capture_script="$REPO_ROOT/scripts/capture-wireguard-credentials.sh"
  restore_script="$REPO_ROOT/scripts/restore-wireguard-credentials.sh"
  require_credential_script "$capture_script"
  require_credential_script "$restore_script"

  # On an upgraded Farcaster, wg0.conf is an identity-only legacy artifact.
  if sudo test -f /etc/wireguard/wormlogic.conf ||
     sudo test -f /etc/wireguard/wg0.conf; then
    local_exists=1
  fi
  if [[ -f "$wireguard_secret_dir/wormlogic.conf.enc" ||
        -f "$wireguard_secret_dir/wg0.conf.enc" ]]; then
    repo_exists=1
  fi

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
    echo "  A complete Wormlogic identity will be generated during VPN setup."
    WIREGUARD_GENERATE_NEW=1
    rm -f -- "$staged_dir/wormlogic.conf" "$staged_dir/wormlogic.public-key"
  fi

  if (( WIREGUARD_GENERATE_NEW == 0 )) &&
     [[ ! -f "$staged_dir/wormlogic.conf" && ! -f "$staged_dir/wg0.conf" ]]; then
    echo "✗ WireGuard reconciliation did not recover a client identity" >&2
    exit 1
  fi
  echo "✓ WireGuard identity and recovery state ready"
}

# --------------------------------------------------
# Set up the standard Wormlogic client exactly like other fleet hosts.
# Preserve Farcaster's existing wg0 key from the previous bootstrap.
# The completed config is then captured using the shared recovery helpers.
# --------------------------------------------------
setup_wormlogic_vpn() {
  local vpn_name="wormlogic"
  local vps_host="vpn.wormlogic.com"
  local vpn_allowed_ips="10.8.0.0/24, 10.42.0.0/16"
  local default_vpn_ip="10.8.0.6/32"
  local credential_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/wireguard"
  local staged_conf="$credential_dir/$vpn_name.conf"
  local legacy_conf="$credential_dir/wg0.conf"
  local staged_public="$credential_dir/$vpn_name.public-key"
  local target_conf="/etc/wireguard/$vpn_name.conf"
  local heighliner_key="$REPO_ROOT/system/vps01/ubuntu/wireguard/heighliner.pub"
  local capture_script="$REPO_ROOT/scripts/capture-wireguard-credentials.sh"
  local restore_script="$REPO_ROOT/scripts/restore-wireguard-credentials.sh"
  local source_conf private_key vpn_ip vps_public_key existing_peer_key generated_conf

  echo "🔐 Setting up Wormlogic WireGuard client..."
  require_credential_script "$capture_script"
  require_credential_script "$restore_script"

  [[ -f "$heighliner_key" ]] || {
    echo "✗ Missing trusted Heighliner WireGuard public key: $heighliner_key" >&2
    exit 1
  }
  vps_public_key="$(tr -d '\r\n' < "$heighliner_key")"
  [[ "$vps_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
    echo "✗ Invalid tracked Heighliner public key" >&2
    exit 1
  }

  mkdir -p "$credential_dir"
  chmod 700 "$credential_dir"
  if [[ -f "$staged_conf" ]]; then
    source_conf="$staged_conf"
    echo "✓ Reusing recovered Wormlogic identity"
  elif [[ -f "$legacy_conf" ]]; then
    source_conf="$legacy_conf"
    echo "✓ Reusing existing Farcaster wg0 key (no new key generated)"
  elif (( WIREGUARD_GENERATE_NEW == 1 )); then
    source_conf=""
    echo "• Generating new WireGuard identity for $EXPECTED_MACHINE..."
  else
    echo "✗ No recovered WireGuard identity found in $credential_dir" >&2
    exit 1
  fi

  if [[ -n "$source_conf" ]]; then
    private_key="$(awk -F '=' '/^[[:space:]]*PrivateKey[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); gsub(/[[:space:]]/, ""); print; exit}' "$source_conf")"
  else
    private_key="$(wg genkey)"
  fi
  if [[ -z "$private_key" ]] || ! printf '%s\n' "$private_key" | wg pubkey >/dev/null 2>&1; then
    echo "✗ Missing or invalid WireGuard private key in $source_conf" >&2
    exit 1
  fi

  vpn_ip=""
  if [[ -n "$source_conf" ]]; then
    vpn_ip="$(awk '
      /^[[:space:]]*\[Interface\][[:space:]]*$/ { in_interface=1; next }
      /^[[:space:]]*\[/ { in_interface=0 }
      in_interface && /^[[:space:]]*Address[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, ""); gsub(/[[:space:]]/, ""); print; exit
      }' "$source_conf")"
  fi
  vpn_ip="${vpn_ip:-${WORMLOGIC_VPN_IP:-$default_vpn_ip}}"
  [[ "$vpn_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || {
    echo "✗ Invalid VPN IP/CIDR: $vpn_ip" >&2
    exit 1
  }

  existing_peer_key=""
  if [[ -n "$source_conf" ]]; then
    existing_peer_key="$(awk '
      /^[[:space:]]*\[Peer\][[:space:]]*$/ { in_peer=1; next }
      /^[[:space:]]*\[/ { in_peer=0 }
      in_peer && /^[[:space:]]*PublicKey[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, ""); gsub(/[[:space:]]/, ""); print; exit
      }' "$source_conf")"
  fi
  if [[ -n "$existing_peer_key" && "$existing_peer_key" != "$vps_public_key" ]]; then
    echo "✗ Recovered Wormlogic peer differs from the tracked Heighliner public key" >&2
    exit 1
  fi

  generated_conf="$(mktemp "$credential_dir/.wormlogic.conf.XXXXXX")"
  chmod 600 "$generated_conf"
  {
    echo "[Interface]"
    echo "PrivateKey = $private_key"
    echo "Address = $vpn_ip"
    echo
    echo "[Peer]"
    echo "PublicKey = $vps_public_key"
    echo "Endpoint = $vps_host:51820"
    echo "AllowedIPs = $vpn_allowed_ips"
    echo "PersistentKeepalive = 25"
  } > "$generated_conf"

  # Install and validate the real wg-quick interface name.
  sudo install -d -m 700 /etc/wireguard
  sudo install -m 600 "$generated_conf" "$target_conf"
  rm -f -- "$generated_conf"
  sudo wg-quick strip "$target_conf" >/dev/null

  # Same authoritative live config -> encrypted recovery -> staged public key
  # reconciliation as the other Wormlogic client bootstraps.
  bash "$capture_script" --force
  bash "$restore_script" --force

  if [[ ! -f "$staged_public" ]] ||
     [[ "$(tr -d '\r\n' < "$staged_public")" != "$(printf '%s\n' "$private_key" | wg pubkey)" ]]; then
    echo "✗ Recovered Wormlogic public key does not match the installed identity" >&2
    exit 1
  fi

  sudo systemctl enable --now "wg-quick@$vpn_name.service"

  WORMLOGIC_VPN_MACHINE_ID="$EXPECTED_MACHINE"
  WORMLOGIC_VPN_PUBLIC_KEY="$(tr -d '\r\n' < "$staged_public")"
  WORMLOGIC_VPN_IP="$vpn_ip"

  echo "✓ Wormlogic WireGuard client configured and enabled for boot"
  echo "  Interface: wormlogic"
  echo "  VPN IP:    $vpn_ip"
  echo "  Config:    $target_conf"
}

# --------------------------------------------------
# Configure shared shell and user environment defaults
# - install Starship when missing
# - expose the standard user PATH
# - servers retain OS/tool defaults for editor/browser choices
# --------------------------------------------------
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

# --------------------------------------------------
# Configure private service resolution
# - host reporting reaches Arrakis through its Wormlogic tunnel address
# - the shared helper owns exactly one /etc/hosts name without disturbing aliases
# --------------------------------------------------
configure_automate_resolution() {
  "$REPO_ROOT/scripts/configure-host-override.sh" 10.8.0.3 automate.wormlogic.com
}

# --------------------------------------------------
# Apply optional machine-specific configuration
# - the bootstrap configures the standard Wormlogic client
# - future configure-system.sh will build the separate acquisitions tunnel
# - service deployment is deliberately NOT part of the host bootstrap
# --------------------------------------------------
configure_host_system() {
  local configure_script="$REPO_ROOT/system/$EXPECTED_MACHINE/$EXPECTED_OS/configure-system.sh"

  if [[ ! -f "$configure_script" ]]; then
    echo "• Acquisitions configure-system.sh not yet present; skipping as planned"
    return 0
  fi

  echo "⚙ Applying Farcaster-specific system configuration..."
  bash "$configure_script"
  echo "✓ Host-specific configuration complete"
}

# --------------------------------------------------
# Refresh WireGuard recovery artifacts from current local state
# - capture whatever live interfaces currently exist (wg0 initially)
# - capture them as encrypted *.conf.enc files and refresh staging/public keys
# --------------------------------------------------
refresh_wireguard_recovery() {
  local capture_script="$REPO_ROOT/scripts/capture-wireguard-credentials.sh"
  local restore_script="$REPO_ROOT/scripts/restore-wireguard-credentials.sh"

  echo "🔐 Refreshing WireGuard recovery state from current configs..."

  require_credential_script "$capture_script"
  require_credential_script "$restore_script"

  bash "$capture_script" --force
  bash "$restore_script" --force

  echo "✓ WireGuard recovery state refreshed"
}

# --------------------------------------------------
# Install root-owned helpers used by scheduled user services
# - capture scripts require the credential helper before credential reconciliation
# - system updates require the update helper before the timer is enabled
# --------------------------------------------------
install_automation_privilege_helpers() {
  local credential_helper_installer="$REPO_ROOT/scripts/install-credential-capture-helper.sh"
  local update_helper_installer="$REPO_ROOT/scripts/install-system-update-helper.sh"

  echo "🔐 Installing scheduled-automation privilege helpers..."

  for installer in "$credential_helper_installer" "$update_helper_installer"; do
    if [[ ! -x "$installer" ]]; then
      echo "✗ Missing or non-executable automation helper installer:"
      echo "  $installer"
      exit 1
    fi
  done

  "$credential_helper_installer"
  "$update_helper_installer"

  sudo -n /usr/local/libexec/wormlogic/credential-capture-root validate >/dev/null || {
    echo "✗ Credential-capture noninteractive privilege validation failed"
    exit 1
  }

  sudo -n /usr/local/libexec/wormlogic/system-update-root validate >/dev/null || {
    echo "✗ System-update noninteractive privilege validation failed"
    exit 1
  }

  echo "✓ Scheduled-automation privilege helpers installed"
}

# --------------------------------------------------
# Install and enable shared user services and timers
# - common maintenance/monitoring units are copied from systemd/
# - unavailable optional units are reported and skipped explicitly
# --------------------------------------------------
user_systemd_available() {
  systemctl --user status >/dev/null 2>&1
}

setup_user_linger() {
  local user_name
  user_name="$(id -un)"

  if [[ "$(loginctl show-user "$user_name" --property=Linger --value 2>/dev/null)" == "yes" ]]; then
    echo "✓ User lingering already enabled for $user_name"
    return 0
  fi

  echo "⚙ Enabling user lingering for $user_name..."
  sudo loginctl enable-linger "$user_name"

  if [[ "$(loginctl show-user "$user_name" --property=Linger --value 2>/dev/null)" != "yes" ]]; then
    echo "✗ Failed to enable user lingering for $user_name"
    exit 1
  fi

  echo "✓ User lingering enabled for $user_name"
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
  local service_source="$REPO_ROOT/systemd/system-update.service"
  local timer_source="$REPO_ROOT/systemd/system-update.timer"

  echo "⚙ Setting up system update service and timer..."

  if ! user_systemd_available; then
    echo "✗ User systemd is required for scheduled system updates"
    exit 1
  fi

  for unit in "$service_source" "$timer_source"; do
    if [[ ! -f "$unit" ]]; then
      echo "✗ Required system-update unit is missing:"
      echo "  $unit"
      exit 1
    fi
  done

  sudo -n /usr/local/libexec/wormlogic/system-update-root validate >/dev/null || {
    echo "✗ System-update privilege helper is not ready"
    exit 1
  }

  setup_user_service_pair "system-update"
}

setup_shared_monitoring() {
  echo "⚙ Setting up shared monitoring services and timers..."
  setup_user_service_pair "disk-space-check"
}

setup_credential_capture() {
  local service_source="$REPO_ROOT/systemd/credential-capture.service"
  local timer_source="$REPO_ROOT/systemd/credential-capture.timer"

  echo "⚙ Setting up scheduled credential capture..."

  if ! user_systemd_available; then
    echo "✗ User systemd is required for scheduled credential capture"
    exit 1
  fi

  for unit in "$service_source" "$timer_source"; do
    if [[ ! -f "$unit" ]]; then
      echo "✗ Required credential-capture unit is missing:"
      echo "  $unit"
      exit 1
    fi
  done

  sudo -n /usr/local/libexec/wormlogic/credential-capture-root validate >/dev/null || {
    echo "✗ Credential-capture privilege helper is not ready"
    exit 1
  }

  setup_user_service_pair "credential-capture"
}


# --------------------------------------------------
# Prepare shell and SSH dotfiles for Stow
# - preserve existing regular files in a timestamped backup
# - leave already-managed symlinks untouched
# --------------------------------------------------
prepare_shell_dotfiles() {
  local backup_dir="$HOME/.dotfile-backups/$(date +%Y%m%d-%H%M%S)"
  local files=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_logout" "$HOME/.ssh/config" "$HOME/.ssh/authorized_keys")

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


# --------------------------------------------------
# Apply the host-specific user environment with GNU Stow
# - each directory under hosts/<machine>/<os>/ is a Stow package
# --------------------------------------------------
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

# --------------------------------------------------
# Run an initial package-state export
# - records the final installed state after bootstrap configuration
# --------------------------------------------------
run_package_export() {
  if [[ -x "$REPO_ROOT/scripts/package-export.sh" ]]; then
    echo "📦 Exporting current package state..."
    "$REPO_ROOT/scripts/package-export.sh"
  else
    echo "⚠ package-export.sh not found or not executable, skipping"
  fi
}

# --------------------------------------------------
# Show final bootstrap state and service summary
# --------------------------------------------------
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
  echo "  - disk-space-check      → local disk usage warning"
  echo "  - credential-capture    → encrypted credential recovery capture"
  echo
  echo "GitHub deploy key for linux-environments:"
  echo "  Repository: linux-environments"
  echo "  Deploy-key title: $EXPECTED_MACHINE"
  echo "  Add with write access enabled:"
  if [[ -f "$HOME/.ssh/id_ed25519_git_linux-environments.pub" ]]; then
    sed 's/^/  /' "$HOME/.ssh/id_ed25519_git_linux-environments.pub"
  else
    echo "  unavailable"
  fi
  echo
  echo "Docker:"
  docker --version || true
  docker compose version || true

  echo
  echo "WireGuard (Wormlogic peer):"
  if [[ -n "${WORMLOGIC_VPN_PUBLIC_KEY:-}" ]]; then
    echo "  Interface: wormlogic"
    echo "  VPN IP:    ${WORMLOGIC_VPN_IP:-unknown}"
    echo "  State:     $(systemctl is-active wg-quick@wormlogic.service 2>/dev/null || true)"
    echo "  Enabled:   $(systemctl is-enabled wg-quick@wormlogic.service 2>/dev/null || true)"
    echo
    echo "Action required on Heighliner:"
    echo "Create system/vps01/ubuntu/wireguard/peers/70-farcaster.conf:"
    echo
    echo "  [Peer]"
    echo "  # Farcaster / vps02"
    echo "  PublicKey = $WORMLOGIC_VPN_PUBLIC_KEY"
    echo "  AllowedIPs = ${WORMLOGIC_VPN_IP:-10.8.0.6/32}"
    echo
    echo "Then rerun Heighliner's WireGuard setup/configure-system reconciliation."
    echo "Handshake can occur after this peer is installed on Heighliner."
  else
    echo "  ✗ Wormlogic not configured"
  fi
  echo "  - Acquisitions tunnel: configure-system.sh stage (not bootstrapped here)"
}

# --------------------------------------------------
# Offer an explicit reboot after bootstrap completion
# --------------------------------------------------
prompt_reboot() {
  local answer=""

  echo
  read -r -p "Reboot now? [y/N] " answer

  case "$answer" in
    y|Y|yes|YES) sudo reboot ;;
    *) echo "• Reboot skipped" ;;
  esac
}

# --------------------------------------------------
# Main bootstrap flow
# - establish the common host baseline and durable credentials
# - configure the standard Wormlogic client; acquisitions configuration is separate
# - finish with user services, Stow, state export, and verification summary
# --------------------------------------------------
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

  # Scheduled capture/update are user services, but privileged operations are
  # delegated to root-owned helpers. Install them before SSH/WireGuard
  # reconciliation because the capture scripts require the credential helper.
  install_automation_privilege_helpers

  # Recover the device's existing age identity before any host secrets are
  # decrypted. This is the linchpin for disaster recovery.
  setup_age_and_sops

  reconcile_ssh_credentials
  configure_linux_environments_git_access
  reconcile_wireguard_credentials
  install_starship
  set_user_environment_defaults

  # Configure and start the Wormlogic client; Heighliner enrollment follows.
  # Acquisitions networking belongs to the separate host configuration stage.
  setup_wormlogic_vpn
  configure_automate_resolution
  configure_host_system
  refresh_wireguard_recovery

  setup_user_linger
  setup_package_export
  setup_system_update
  setup_shared_monitoring
  setup_credential_capture
  prepare_shell_dotfiles
  apply_host_environment
  run_package_export
  show_summary
  prompt_reboot
}

main "$@"
