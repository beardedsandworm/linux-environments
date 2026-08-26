# Wormlogic automatic VPN selection — laptop01 / Arch

This revision matches laptop01's existing Arch networking stack: **iwd**, not
NetworkManager. It does not install or require NetworkManager.

## Policy

| Current network | Result |
| --- | --- |
| Home | `pvp-down`, `vpn-down` |
| Trusted away from home | `pvp-down`, `vpn-up` |
| Unknown/untrusted | `vpn-down`, `pvp-up` |
| No default network | both tunnels down |

## Network identity

The automation deliberately distinguishes Wi-Fi and Ethernet.

- **Wi-Fi:** iwd's connected SSID plus security class is hashed into a stable
  `wifi:<sha256>` fingerprint. BSSID is not included, so roaming between access
  points on the same known Wi-Fi network does not create a new identity.
- **Ethernet:** the default gateway's link-layer/MAC address is hashed into an
  `ethernet:<sha256>` fingerprint. This lets the same Ethernet adapter identify
  home versus an unfamiliar wired network.
- If a wired gateway cannot yet be fingerprinted, automatic policy fails safe
  and treats the network as untrusted. `network-home` / `network-trust` refuse
  to save an unstable identity.

The files `trusted-networks` and `home-networks` contain only hashes, not SSIDs.
They are part of the normal laptop01 Stow package, so edits are Git-backed.

## Trigger model

No NetworkManager dispatcher is used. A Stowed user service runs `ip monitor`
and wakes the one-shot reconciler when links, addresses, or routes change. The
reconciler waits two seconds, re-reads the current default physical route, then
calls the existing `vpn-up/down` and `pvp-up/down` commands.

The watcher sees VPN route changes too; that is harmless because reconciliation
is idempotent and only notifies on actual tunnel transitions.

## Repo layout

```text
scripts/
└── install-wireguard-sudoers.sh   # existing helper role, extended for PVP

system/laptop01/arch/vpn-auto/
└── setup.sh

hosts/laptop01/arch/vpn-auto/
├── .config/systemd/user/
│   ├── wormlogic-vpn-auto.service
│   └── wormlogic-vpn-auto-watch.service
├── .config/wormlogic-vpn/
│   ├── home-networks
│   └── trusted-networks
├── .local/lib/wormlogic-vpn/
│   └── network.sh
└── .local/bin/
    ├── network-home
    ├── network-list
    ├── network-revoke
    ├── network-trust
    ├── vpn-auto
    └── vpn-auto-watch
```

`setup.sh` uses the repository's established `scripts/install-wireguard-sudoers.sh`
workflow. The supplied version keeps Wormlogic's existing non-interactive
start/stop authorization and adds only the exact PVP `systemctl`, `wg`, and `ip`
operations used by the current commands.

## Install now

From the repository root:

```bash
./system/laptop01/arch/vpn-auto/setup.sh
```

Then, while connected at home:

```bash
network-home
```

Other commands:

```bash
network-trust
network-revoke
network-list
```

## Bootstrap integration

The main laptop bootstrap already invokes `scripts/install-wireguard-sudoers.sh`.
Add the VPN automation setup to `system/laptop01/arch/configure-system.sh`:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/vpn-auto/setup.sh"
```

The later host Stow pass is idempotent.

## Diagnostics

```bash
systemctl --user status wormlogic-vpn-auto-watch.service
systemctl --user status wormlogic-vpn-auto.service
journalctl --user -u wormlogic-vpn-auto.service
network-list
vpn-status
pvp-status
```

## v2.1 setup verifier correction

GNU Stow may fold an entire directory into a symlink when the target directory
is otherwise absent. `setup.sh` therefore verifies the resolved path of the
Git-backed registry files rather than requiring each registry file itself to be
a symbolic link. Both Stow representations are valid and supported.
