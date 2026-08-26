#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
HOST_STOW_DIR="$REPO_ROOT/hosts/laptop01/arch"
STOW_PACKAGE="vpn-auto"
SUDOERS_INSTALLER="$REPO_ROOT/scripts/install-wireguard-sudoers.sh"
VPN_USER="${SUDO_USER:-${USER:-}}"

if [[ -z "$VPN_USER" || "$VPN_USER" == "root" ]]; then
    echo "✗ Run this setup as the normal workstation user, not from a root shell." >&2
    exit 1
fi

VPN_HOME="$(getent passwd "$VPN_USER" | cut -d: -f6)"
[[ -n "$VPN_HOME" ]] || { echo "✗ Could not determine home directory for $VPN_USER." >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || { echo "✗ Required command not found: $1" >&2; exit 1; }
}

for command_name in stow iwctl ip systemctl sudo getent sha256sum readlink; do
    require_command "$command_name"
done

[[ -d "$HOST_STOW_DIR/$STOW_PACKAGE" ]] || { echo "✗ Missing Stow package: $HOST_STOW_DIR/$STOW_PACKAGE" >&2; exit 1; }
[[ -x "$SUDOERS_INSTALLER" ]] || { echo "✗ Missing existing sudoers helper: $SUDOERS_INSTALLER" >&2; exit 1; }

commands_ready=1
for command_name in vpn-up vpn-down pvp-up pvp-down; do
    if [[ ! -x "$VPN_HOME/.local/bin/$command_name" ]]; then
        commands_ready=0
        echo "⚠ Existing VPN command is not stowed yet: $VPN_HOME/.local/bin/$command_name"
    fi
done

echo "🔗 Stowing laptop01 VPN automation..."
stow -d "$HOST_STOW_DIR" -t "$VPN_HOME" "$STOW_PACKAGE"

verify_stow_managed_file() {
    local managed_file="$1" source_file="$2" managed_real source_real

    [[ -e "$managed_file" ]] || {
        echo "✗ Expected Stow-managed file was not created: $managed_file" >&2
        exit 1
    }

    managed_real="$(readlink -f -- "$managed_file")"
    source_real="$(readlink -f -- "$source_file")"

    if [[ -z "$managed_real" || -z "$source_real" || "$managed_real" != "$source_real" ]]; then
        echo "✗ File exists but does not resolve to the Git-backed Stow source:" >&2
        echo "  Managed: $managed_file" >&2
        echo "  Source:  $source_file" >&2
        echo "  Resolved managed: ${managed_real:-unresolved}" >&2
        echo "  Resolved source:  ${source_real:-unresolved}" >&2
        exit 1
    fi
}

verify_stow_managed_file \
    "$VPN_HOME/.config/wormlogic-vpn/trusted-networks" \
    "$HOST_STOW_DIR/$STOW_PACKAGE/.config/wormlogic-vpn/trusted-networks"
verify_stow_managed_file \
    "$VPN_HOME/.config/wormlogic-vpn/home-networks" \
    "$HOST_STOW_DIR/$STOW_PACKAGE/.config/wormlogic-vpn/home-networks"

echo "🔐 Updating existing WireGuard sudo authorization..."
"$SUDOERS_INSTALLER"

# Remove the obsolete NetworkManager hook from the first draft if it ever made
# it onto the machine. This is a migration cleanup, not part of normal operation.
if sudo test -e /etc/NetworkManager/dispatcher.d/90-wormlogic-vpn-auto 2>/dev/null; then
    echo "• Removing obsolete NetworkManager dispatcher hook..."
    sudo rm -f /etc/NetworkManager/dispatcher.d/90-wormlogic-vpn-auto
fi

echo "⚙ Enabling user VPN automation..."
systemctl --user daemon-reload
systemctl --user enable wormlogic-vpn-auto.service >/dev/null
systemctl --user enable --now wormlogic-vpn-auto-watch.service >/dev/null

if command -v notify-send >/dev/null 2>&1; then
    echo "✓ Desktop notifications available"
else
    echo "⚠ notify-send not found; automation will work but desktop notifications are unavailable."
fi

if (( commands_ready )); then
    echo "🔎 Running initial reconciliation..."
    systemctl --user start wormlogic-vpn-auto.service
else
    echo "• Initial reconciliation deferred until the established VPN commands are stowed."
fi

echo "✓ Wormlogic VPN automation configured"
echo "  Home:    network-home"
echo "  Trust:   network-trust"
echo "  Revoke:  network-revoke"
echo "  List:    network-list"
