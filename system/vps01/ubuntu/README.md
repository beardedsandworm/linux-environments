# Heighliner bootstrap refactor

This bundle is the revised `vps01` bootstrap/network proposal. It separates the
machine bootstrap from Heighliner-specific networking and makes the existing
WireGuard identities recoverable from the repository.

## Intended ownership

- `bootstrap.sh` — generic Ubuntu/VPS bootstrap flow.
- `configure-system.sh` — vps01-only orchestrator. It contains no tunnel logic.
- `wireguard/setup.sh` — original Wormlogic `wg0` tunnel and its forwarding
  policy.
- `pvp/setup.sh` — `wg-pvp`, `wg-proton`, PVP policy routing, NAT and kill
  switch.
- `scripts/capture-age-key.sh` / `restore-age-key.sh` — universal age identity
  escrow/recovery using `~/.config/dotfiles/machine-id`.
- `scripts/capture-vps01-wireguard-state.sh` — one-time/current-state capture of
  all three Heighliner WireGuard identities plus safe wg-pvp peer state.

## Project tree

```text
scripts/
├── capture-age-key.sh
├── restore-age-key.sh
└── capture-vps01-wireguard-state.sh

secrets/
└── vps01/
    ├── README.md
    ├── age-key.age              # created by capture-age-key.sh
    ├── wg0.key.enc              # created by capture-vps01-wireguard-state.sh
    ├── wg-pvp.key.enc           # created by capture-vps01-wireguard-state.sh
    └── wg-proton.conf.enc       # created by capture-vps01-wireguard-state.sh

system/vps01/ubuntu/
├── bootstrap.sh
├── configure-system.sh
├── wireguard/
│   ├── setup.sh
│   ├── heighliner.pub
│   ├── sysctl.conf
│   ├── wormlogic.nft
│   ├── wormlogic-wg.service
│   └── peers/
│       ├── 10-midway.conf
│       ├── 20-arrakis.conf
│       ├── 30-ix.conf
│       ├── 40-laptop01.conf
│       ├── 50-laptop02.conf
│       └── 60-pixel8pro.conf
└── pvp/
    ├── setup.sh
    ├── pvp-routing.sh
    ├── pvp.nft
    ├── wormlogic-pvp.service
    ├── heighliner.pub            # created by capture script
    ├── proton-client.pub         # created by capture script
    └── peers/
        ├── README.md
        └── current.conf          # created by capture script
```

The bundle intentionally does **not** include or replace your existing
`system/vps01/ubuntu/apt.txt`. Merge these files into the existing repository so
your package list is retained. The list must provide at least the commands used
here, notably `age`, WireGuard (`wg`/`wg-quick`), `nft`, `stow`, Git, curl and the
normal server tools already used by the bootstrap.

## Refactored bootstrap flow

The important ordering is now:

```text
verify machine-id
  ↓
packages / Docker
  ↓
restore existing age identity from secrets/<machine-id>/age-key.age
  OR generate an identity only when no encrypted device secrets exist
  ↓
ensure SOPS
  ↓
configure-system.sh
  ├── wireguard/setup.sh   (wg0 first)
  └── pvp/setup.sh         (depends on wg0)
  ↓
normal monitoring/stow/export work
```

The persistent machine ID remains:

```text
~/.config/dotfiles/machine-id
```

That file must identify a replacement Heighliner as `vps01` before running the
bootstrap, just as the existing bootstrap already requires.

## Wormlogic wg0 captured state

The committed peer files reflect the live state supplied from Heighliner:

- Heighliner: `10.8.0.1/24`, UDP 51820
- Midway: `10.8.0.2/32` plus routed `10.42.42.0/24`, keepalive 25
- Arrakis: `10.8.0.3/32`
- IX: `10.8.0.4/32`
- laptop01: `10.8.0.10/32`
- laptop02: `10.8.0.11/32`
- Pixel 8 Pro: `10.8.0.20/32`

Dynamic peer `Endpoint=` values from the old `/etc/wireguard/wg0.conf` are not
reproduced. Heighliner is the listening hub and learns roaming peer endpoints at
runtime.

The known Heighliner wg0 public identity is committed as:

```text
O8SmQdIDV3+SJMldSQoYWV6neF39SPQSz7iMnQGnWz4=
```

`wireguard/setup.sh` refuses to install a recovered private key if it does not
derive to that public key.

## Routing/sysctl baseline

The live known-good state is preserved:

```text
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
```

The previous proposal's `rp_filter=0` behavior has been removed. PVP explicitly
keeps existing network interfaces in loose mode (`2`).

The old duplicated iptables wg0 forwarding rules are **not** part of the
recovery definition. The new design owns one small nftables table that permits
`wg0 -> wg0` forwarding without modifying Docker's iptables-nft tables.

## Capture the current Heighliner

After merging/pushing this bundle and pulling it onto the current Heighliner:

### 1. Escrow the machine age identity

```bash
./scripts/capture-age-key.sh
```

This creates:

```text
secrets/vps01/age-key.age
```

It is encrypted with an independent passphrase, not with SOPS. Store that
passphrase outside Git. The script verifies the recovery blob before installing
it.

### 2. Capture all three WireGuard identities

```bash
./scripts/capture-vps01-wireguard-state.sh
```

This captures, without printing private keys:

```text
/etc/wireguard/wg0.conf
    private key -> secrets/vps01/wg0.key.enc

/etc/wireguard/wg-pvp.conf
    private key -> secrets/vps01/wg-pvp.key.enc
    public peer sections -> pvp/peers/current.conf

/etc/wireguard/wg-proton.conf
    complete provider profile -> secrets/vps01/wg-proton.conf.enc
```

It also records the wg-pvp and Proton client public identities. Before writing
recovery state it verifies that the private keys in all three persistent config
files derive to the public keys of the corresponding *running* interfaces. That
prevents persistent/runtime drift from being silently committed.

`wg-pvp` dynamic `Endpoint=` lines are omitted. If `wg-pvp.conf` contains a
`PresharedKey=`, the capture aborts rather than place that secret in Git-managed
peer configuration.

Use `--force` only when intentionally refreshing existing captured state.

### 3. Review and commit

```bash
git status
git diff -- system/vps01/ubuntu
```

SOPS ciphertext can be sanity-checked without printing a private key, for
example:

```bash
sops --decrypt --input-type json --output-type binary \
  secrets/vps01/wg0.key.enc | wg pubkey
```

It should output the committed Heighliner wg0 public key.

Once reviewed, commit/push the encrypted secrets and captured public state.

## Applying the refactor to the current Heighliner

After the capture files exist, you do not need to rerun the entire bootstrap to
adopt the network refactor. Run:

```bash
./system/vps01/ubuntu/configure-system.sh
```

It applies components in this order:

```text
Wormlogic wg0
  ↓
PVP gateway
```

If a WireGuard interface is already active, the setup uses `wg syncconf` rather
than deliberately tearing it down. On a replacement machine, the corresponding
`wg-quick@...` service is started normally from the rebuilt configuration.

## Disaster recovery path

On a replacement VPS:

1. Establish the normal user and set its persistent machine ID to `vps01` using
   your existing provisioning process.
2. Clone/pull the repository.
3. Ensure the provider firewall permits UDP 51820 and 51821.
4. Run the normal vps01 bootstrap.
5. Bootstrap sees `secrets/vps01/age-key.age` and invokes
   `scripts/restore-age-key.sh` before attempting to decrypt host secrets.
6. Enter the independent age-recovery passphrase.
7. `wireguard/setup.sh` restores the same wg0 identity and peer set.
8. `pvp/setup.sh` restores the same wg-pvp identity and complete Proton profile,
   then installs the fail-closed routing/firewall layer.
9. Point the public DNS name used by Wormlogic clients at the replacement VPS if
   its public IP changed.

Existing WireGuard clients therefore retain their peer identity/configuration;
the replacement server presents the same public keys.

## PVP design retained

- PVP subnet: `10.9.0.0/24`
- Heighliner: `10.9.0.1/24`, UDP 51821
- table 200 (`pvp`) routes PVP Internet to `wg-proton`
- an unreachable fallback remains in table 200
- firewall permits `wg-pvp -> wg-proton`, approved private traffic via `wg0`,
  and Pi-hole through deterministic Docker bridge `br-pihole`
- `wg-pvp -> eth0` is dropped
- NAT applies only to `10.9.0.0/24 -> wg-proton`
- PVP-to-home/private traffic is not NATed

The PVP policy assumes the `vps-services` Pi-hole network remains deterministic:

```text
bridge:  br-pihole
subnet:  172.21.0.0/24
Pi-hole: 172.21.0.2
```

That Docker service/network remains the responsibility of the `vps-services`
repository, not this OS bootstrap.

## Still external / not encoded here

- Provider firewall UDP 51820 (Wormlogic) and UDP 51821 (PVP).
- Public DNS failover to a replacement VPS.
- Midway's eventual return route/AllowedIPs for `10.9.0.0/24` if preserving
  source addresses for PVP -> home traffic. This was not yet implemented/tested
  and is intentionally not invented here.
