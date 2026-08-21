#!/usr/bin/env bash

set -euo pipefail

# --------------------------------------------------
# Resolve repo root and local config paths
# --------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACHINE_ID_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/machine-id"
WEBHOOK_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/discord-webhook"
N8N_WEBHOOK_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/n8n-webhook"

# --------------------------------------------------
# Detect operating system by available package manager
# --------------------------------------------------
detect_os() {
  if command -v pacman >/dev/null 2>&1; then
    echo "arch"
  elif command -v apt >/dev/null 2>&1; then
    echo "ubuntu"
  else
    echo "unsupported"
  fi
}

# --------------------------------------------------
# Map machine ID to friendly display name
# --------------------------------------------------
machine_label() {
  case "$1" in
  laptop01) echo "Dell Precision" ;;
  laptop02) echo "HP Envy" ;;
  desktop01) echo "Covid PC" ;;
  server01) echo "Docker Server" ;;
  server02) echo "Dell Tower" ;;
  server03) echo "Terramaster" ;;
  vps01) echo "Wormlogic VPS" ;;
  *) echo "Unknown Machine" ;;
  esac
}

# --------------------------------------------------
# Prompt user to select target machine
# - menu text goes to stderr
# - only the machine ID goes to stdout
# --------------------------------------------------
prompt_machine() {
  local choice

  while true; do
    {
      echo " Select target machine:"
      echo " 1) Dell Precision"
      echo " 2) HP Envy"
      echo " 3) Covid PC"
      echo " 4) Docker Server"
      echo " 5) Wormlogic VPS"
      echo " 6) Dell Tower"
      echo " 7) Terramaster"
      echo " 0) Exit"
    } >&2

    read -r -p "Enter choice [0]: " choice >&2
    choice="${choice:-0}"

    case "$choice" in
    1)
      echo "laptop01"
      return 0
      ;;
    2)
      echo "laptop02"
      return 0
      ;;
    3)
      echo "desktop01"
      return 0
      ;;
    4)
      echo "server01"
      return 0
      ;;
    5)
      echo "vps01"
      return 0
      ;;
    6)
      echo "server02"
      return 0
      ;;
    7)
      echo "server03"
      return 0
      ;;
    0)
      echo "exit"
      return 0
      ;;
    *)
      {
        echo "✗ Invalid selection: $choice"
        echo " Please choose 0-7"
        echo
      } >&2
      ;;
    esac
  done
}

# --------------------------------------------------
# Prompt for Git identity
# --------------------------------------------------
prompt_git_config() {
  local current_name current_email git_name git_email

  current_name="$(git config --global user.name || true)"
  current_email="$(git config --global user.email || true)"

  echo
  echo "🔧 Git configuration"
  read -r -p "Git username [${current_name:-unset}]: " git_name
  read -r -p "Git email [${current_email:-unset}]: " git_email

  if [[ -n "$git_name" ]]; then
    git config --global user.name "$git_name"
    echo "✓ Set git user.name to '$git_name'"
  fi

  if [[ -n "$git_email" ]]; then
    git config --global user.email "$git_email"
    echo "✓ Set git user.email to '$git_email'"
  fi
}

# --------------------------------------------------
# Prompt for Discord webhook
# - blank input keeps existing value or skips setup
# --------------------------------------------------
prompt_discord_webhook() {
  local current_webhook new_webhook

  mkdir -p "$(dirname "$WEBHOOK_FILE")"

  if [[ -f "$WEBHOOK_FILE" ]]; then
    current_webhook="$(<"$WEBHOOK_FILE")"
  else
    current_webhook=""
  fi

  echo
  echo "📣 Discord webhook configuration"
  echo "   Example:"
  echo "   https://discord.com/api/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz"
  echo "   Leave blank to keep current value or skip."
  read -r -p "Discord webhook [${current_webhook:-unset}]: " new_webhook

  if [[ -n "$new_webhook" ]]; then
    printf "%s\n" "$new_webhook" >"$WEBHOOK_FILE"
    chmod 600 "$WEBHOOK_FILE"
    echo "✓ Discord webhook saved to $WEBHOOK_FILE"
  elif [[ -n "$current_webhook" ]]; then
    echo "✓ Keeping existing Discord webhook"
  else
    echo "• No Discord webhook configured"
  fi
}

# --------------------------------------------------
# Prompt for n8n webhook
# - blank input keeps existing value or skips setup
# --------------------------------------------------
prompt_n8n_webhook() {
  local current_webhook new_webhook

  mkdir -p "$(dirname "$N8N_WEBHOOK_FILE")"

  if [[ -f "$N8N_WEBHOOK_FILE" ]]; then
    current_webhook="$(<"$N8N_WEBHOOK_FILE")"
  else
    current_webhook=""
  fi

  echo
  echo " n8n webhook configuration"
  echo " Example:"
  echo " https://automate.wormlogic.com/webhook/events"
  echo " Leave blank to keep current value or skip."

  read -r -p "n8n webhook [${current_webhook:-unset}]: " new_webhook

  if [[ -n "$new_webhook" ]]; then
    printf "%s\n" "$new_webhook" >"$N8N_WEBHOOK_FILE"
    chmod 600 "$N8N_WEBHOOK_FILE"
    echo "✓ n8n webhook saved to $N8N_WEBHOOK_FILE"
  elif [[ -n "$current_webhook" ]]; then
    echo "✓ Keeping existing n8n webhook"
  else
    echo "• No n8n webhook configured"
  fi
}

# --------------------------------------------------
# Set or verify machine identity
# --------------------------------------------------
set_machine_id() {
  local selected_machine="$1"
  local existing_machine
  local confirm

  mkdir -p "$(dirname "$MACHINE_ID_FILE")"

  if [[ ! -f "$MACHINE_ID_FILE" ]]; then
    echo
    echo "🪪 No machine-id found. Creating one..."
    printf "%s\n" "$selected_machine" >"$MACHINE_ID_FILE"
    echo "✓ Machine ID set to: $selected_machine"
    return 0
  fi

  existing_machine="$(<"$MACHINE_ID_FILE")"

  if [[ "$existing_machine" == "$selected_machine" ]]; then
    echo
    echo "🪪 Machine ID already set correctly: $existing_machine"
    return 0
  fi

  echo
  echo "⚠ Existing machine-id does not match selection."
  echo "   Current:  $existing_machine"
  echo "   Selected: $selected_machine"
  read -r -p "Overwrite machine-id with '$selected_machine'? [y/N]: " confirm
  confirm="${confirm:-N}"

  case "$confirm" in
  y | Y)
    printf "%s\n" "$selected_machine" >"$MACHINE_ID_FILE"
    echo "✓ Machine ID updated to: $selected_machine"
    ;;
  *)
    echo "↩ Aborting to avoid overwriting machine-id."
    exit 1
    ;;
  esac
}

# --------------------------------------------------
# Final confirmation before bootstrap
# --------------------------------------------------
confirm_execution() {
  local confirm
  echo
  read -r -p "⚠ Proceed with bootstrap? [y/N]: " confirm
  confirm="${confirm:-N}"

  case "$confirm" in
  y | Y) ;;
  *)
    echo "↩ Aborted."
    exit 0
    ;;
  esac
}

# --------------------------------------------------
# Main installer flow
# --------------------------------------------------
main() {
  local machine machine_name distro bootstrap_path existing_machine

  machine="$(prompt_machine)"

  case "$machine" in
  exit)
    echo "↩ Exiting."
    exit 0
    ;;
  esac

  machine_name="$(machine_label "$machine")"

  distro="$(detect_os)"
  if [[ "$distro" == "unsupported" ]]; then
    echo "✗ Unsupported operating system."
    exit 1
  fi

  set_machine_id "$machine"

  bootstrap_path="$REPO_ROOT/system/$machine/$distro/bootstrap.sh"

  if [[ ! -f "$bootstrap_path" ]]; then
    echo
    echo "✗ Bootstrap not found: $bootstrap_path"
    exit 1
  fi

  echo
  echo "ℹ Installation target:"
  echo "   Machine: $machine_name ($machine)"
  echo "   OS:      $distro"
  echo "   Script:  $bootstrap_path"

  if [[ -f "$MACHINE_ID_FILE" ]]; then
    existing_machine="$(<"$MACHINE_ID_FILE")"
    echo "   ID File: $existing_machine"
  fi

  prompt_git_config
  prompt_discord_webhook
  prompt_n8n_webhook
  confirm_execution

  echo
  echo "🚀 Launching bootstrap for $machine_name on $distro..."
  exec "$bootstrap_path" "$machine"
}

main "$@"
