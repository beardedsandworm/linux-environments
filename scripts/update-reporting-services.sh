#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
N8N_WEBHOOK_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/n8n-webhook"
RETIRED_SERVICES=(repo-update-check dotfiles-change-check)
CURRENT_SERVICES=(disk-space-check package-export system-update)

log() {
  printf '[update-reporting-services] %s\n' "$*"
}

command -v systemctl >/dev/null 2>&1 || {
  log "ERROR: systemctl is required"
  exit 1
}
[[ -s "$N8N_WEBHOOK_FILE" ]] || {
  log "ERROR: n8n webhook is missing or empty: $N8N_WEBHOOK_FILE"
  exit 1
}

for name in "${CURRENT_SERVICES[@]}"; do
  for suffix in service timer; do
    [[ -f "$REPO_ROOT/systemd/$name.$suffix" ]] || {
      log "ERROR: repository unit is missing: systemd/$name.$suffix"
      exit 1
    }
  done
done

mkdir -p "$USER_UNIT_DIR"

for name in "${RETIRED_SERVICES[@]}"; do
  log "Retiring $name"
  if ! systemctl --user disable --now "$name.timer" >/dev/null 2>&1; then
    if systemctl --user is-enabled --quiet "$name.timer" || systemctl --user is-active --quiet "$name.timer"; then
      log "ERROR: could not disable or stop $name.timer"
      exit 1
    fi
  fi
  if ! systemctl --user stop "$name.service" >/dev/null 2>&1; then
    if systemctl --user is-active --quiet "$name.service"; then
      log "ERROR: could not stop $name.service"
      exit 1
    fi
  fi
  rm -f "$USER_UNIT_DIR/$name.service" "$USER_UNIT_DIR/$name.timer"
done

for name in "${CURRENT_SERVICES[@]}"; do
  log "Installing $name units"
  install -m 0644 "$REPO_ROOT/systemd/$name.service" "$USER_UNIT_DIR/$name.service"
  install -m 0644 "$REPO_ROOT/systemd/$name.timer" "$USER_UNIT_DIR/$name.timer"
done

systemctl --user daemon-reload
systemctl --user reset-failed >/dev/null 2>&1 || true

for name in "${CURRENT_SERVICES[@]}"; do
  systemctl --user enable --now "$name.timer"
  systemctl --user is-enabled --quiet "$name.timer"
  systemctl --user is-active --quiet "$name.timer"
done

for name in "${RETIRED_SERVICES[@]}"; do
  if [[ -e "$USER_UNIT_DIR/$name.service" || -e "$USER_UNIT_DIR/$name.timer" ]]; then
    log "ERROR: retired unit files remain for $name"
    exit 1
  fi
  if systemctl --user is-enabled --quiet "$name.timer"; then
    log "ERROR: retired timer remains enabled: $name.timer"
    exit 1
  fi
  if systemctl --user is-active --quiet "$name.timer" || systemctl --user is-active --quiet "$name.service"; then
    log "ERROR: retired unit remains active: $name"
    exit 1
  fi
done

log "Reporting services are current. No jobs were run manually."
