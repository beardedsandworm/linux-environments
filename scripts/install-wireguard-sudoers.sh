#!/usr/bin/env bash
set -euo pipefail

SERVICE="wg-quick@wormlogic.service"
TARGET="/etc/sudoers.d/wormlogic-wireguard"

if id -nG "$USER" | grep -qw wheel; then
    admin_group="wheel"
elif id -nG "$USER" | grep -qw sudo; then
    admin_group="sudo"
else
    printf 'User %s is not in wheel or sudo.\n' "$USER" >&2
    exit 1
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

cat > "$tmp_file" <<EOF
Cmnd_Alias WORMLOGIC_WIREGUARD = \\
    /usr/bin/systemctl start ${SERVICE}, \\
    /usr/bin/systemctl stop ${SERVICE}

%${admin_group} ALL=(root) NOPASSWD: WORMLOGIC_WIREGUARD
EOF

chmod 0440 "$tmp_file"

sudo visudo -cf "$tmp_file"
sudo install -o root -g root -m 0440 "$tmp_file" "$TARGET"
sudo visudo -cf "$TARGET"

printf 'Installed %s for group %s.\n' "$TARGET" "$admin_group"
