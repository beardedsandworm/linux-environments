# Heighliner bootstrap refactor

This document describes the current `vps01` bootstrap and network-recovery model.

The design separates machine bootstrap from Heighliner-specific networking while preserving Heighliner's existing WireGuard identities and complete interface configurations in encrypted recovery state.

## Intended ownership

- `bootstrap.sh` — generic Ubuntu/VPS bootstrap flow.
- `configure-system.sh` — `vps01`-specific orchestrator. It contains no tunnel-specific implementation logic.
- `wireguard/setup.sh` — Wormlogic `wg0` tunnel and its forwarding policy.
- `pvp/setup.sh` — `wg-pvp`, `wg-proton`, PVP policy routing, NAT, and kill switch.
- `scripts/capture-age-key.sh` / `restore-age-key.sh` — universal age identity escrow/recovery using `~/.config/dotfiles/machine-id`.
- `scripts/capture-vps01-wireguard-state.sh` — capture/reconciliation of Heighliner's persistent WireGuard configuration for encrypted recovery.

Host WireGuard recovery belongs to `linux-environments`.

Application and service recovery on Heighliner belongs to `vps-services`.

---

## Project tree

```text
scripts/
├── capture-age-key.sh
├── restore-age-key.sh
└── capture-vps01-wireguard-state.sh

secrets/
└── vps01/
    ├── README.md
    ├── age-key.age
    └── wireguard/
        ├── wg0.conf.enc
        ├── wg-pvp.conf.enc
        └── wg-proton.conf.enc

system/vps01/ubuntu/
├── bootstrap.sh
├── configure-system.sh
├── wireguard/
│   ├── setup.sh
│   ├── heighliner.pub
│   ├── sysctl.conf
│   ├── wormlogic.nft
│   └── wormlogic-wg.service
└── pvp/
    ├── setup.sh
    ├── pvp-routing.sh
    ├── pvp.nft
    └── wormlogic-pvp.service
```

Additional public peer/reference files may exist under the component directories where required by the setup implementation, but they are **not the recovery authority for the WireGuard interfaces**.

The authoritative recovery state is:

```text
secrets/vps01/wireguard/*.conf.enc
```

The repository's existing:

```text
system/vps01/ubuntu/apt.txt
```

remains authoritative for the package set and is not replaced by this network-recovery design.

It must provide at least the commands used by the bootstrap, including:

- `age`
- SOPS
- WireGuard (`wg` / `wg-quick`)
- `nft`
- `stow`
- Git
- curl
- normal server/bootstrap utilities already used by the host

---

## Refactored bootstrap flow

The important ordering is:

```text
verify machine-id
        ↓
packages / Docker
        ↓
restore existing age identity
from secrets/<machine-id>/age-key.age

OR

generate a new age identity only when
no encrypted machine state exists
        ↓
ensure SOPS
        ↓
configure-system.sh
    ├── wireguard/setup.sh
    │       └── restore/reconcile wg0
    │
    └── pvp/setup.sh
            ├── restore/reconcile wg-pvp
            └── restore/reconcile wg-proton
        ↓
normal monitoring / stow / export work
```

The persistent machine ID remains:

```text
~/.config/dotfiles/machine-id
```

A replacement Heighliner must identify itself as:

```text
vps01
```

before machine-specific recovery is attempted.

---

## Age identity recovery

Heighliner's age identity recovery artifact is:

```text
secrets/vps01/age-key.age
```

It is encrypted independently with:

```text
age --passphrase
```

rather than SOPS.

This is intentional.

The machine age identity is required before SOPS can decrypt:

```text
secrets/vps01/wireguard/*.conf.enc
```

and other machine-specific encrypted recovery state.

The passphrase for `age-key.age` must remain outside Git.

The live restored identity belongs at:

```text
~/.config/sops/age/keys.txt
```

---

## WireGuard recovery authority

Heighliner has three persistent WireGuard interfaces:

```text
wg0
wg-pvp
wg-proton
```

Their encrypted recovery artifacts are:

```text
secrets/vps01/wireguard/wg0.conf.enc
secrets/vps01/wireguard/wg-pvp.conf.enc
secrets/vps01/wireguard/wg-proton.conf.enc
```

Each artifact contains the **complete persistent configuration** for its corresponding interface.

The model is:

```text
/etc/wireguard/wg0.conf
        ↓ capture
secrets/vps01/wireguard/wg0.conf.enc

/etc/wireguard/wg-pvp.conf
        ↓ capture
secrets/vps01/wireguard/wg-pvp.conf.enc

/etc/wireguard/wg-proton.conf
        ↓ capture
secrets/vps01/wireguard/wg-proton.conf.enc
```

and during recovery:

```text
secrets/vps01/wireguard/*.conf.enc
        ↓ SOPS decrypt
/etc/wireguard/*.conf
        ↓
wg-quick / systemd reconciliation
```

This replaces the previous split-key model.

The following artifacts are obsolete and are **not** recovery inputs:

```text
secrets/vps01/wg0.key.enc
secrets/vps01/wg-pvp.key.enc
secrets/vps01/wg-proton.conf.enc
```

The current Proton artifact is instead:

```text
secrets/vps01/wireguard/wg-proton.conf.enc
```

Do not create separate recovery copies of individual WireGuard private keys.

---

## Wormlogic `wg0`

The current Wormlogic topology is:

```text
Heighliner   10.8.0.1/24   UDP 51820
Midway       10.8.0.2/32
Arrakis      10.8.0.3/32
IX           10.8.0.4/32
laptop01     10.8.0.10/32
laptop02     10.8.0.11/32
Pixel 8 Pro  10.8.0.20/32
```

Midway additionally carries the appropriate routed Wormlogic/home-network prefixes and uses persistent keepalive where required.

Heighliner is the listening WireGuard hub.

Roaming client endpoint information learned dynamically by the running WireGuard interface is runtime state and is not the recovery authority.

The capture process reads the persistent configuration under:

```text
/etc/wireguard/
```

rather than attempting to reconstruct recovery configuration from runtime `wg` output.

The known Heighliner `wg0` public identity is:

```text
O8SmQdIDV3+SJMldSQoYWV6neF39SPQSz7iMnQGnWz4=
```

Recovery should refuse to install a `wg0` configuration whose private key derives to a different public identity.

---

## Routing/sysctl baseline

The known-good host routing baseline is:

```text
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
```

PVP uses loose reverse-path filtering rather than disabling it globally.

The obsolete duplicated iptables forwarding rules are not part of the recovery definition.

The current design owns an explicit nftables policy for Wormlogic/PVP forwarding without treating Docker's generated iptables-nft state as configuration authority.

---

## Capture the current Heighliner

### 1. Escrow the machine age identity

Run:

```bash
./scripts/capture-age-key.sh
```

This creates or refreshes:

```text
secrets/vps01/age-key.age
```

The artifact is encrypted with an independent passphrase.

Store that passphrase outside Git.

The recovery blob should be verified by the capture process before it is considered valid.

---

### 2. Capture WireGuard recovery state

Run:

```bash
./scripts/capture-vps01-wireguard-state.sh
```

The capture process records the complete persistent configurations:

```text
/etc/wireguard/wg0.conf
    ↓
secrets/vps01/wireguard/wg0.conf.enc

/etc/wireguard/wg-pvp.conf
    ↓
secrets/vps01/wireguard/wg-pvp.conf.enc

/etc/wireguard/wg-proton.conf
    ↓
secrets/vps01/wireguard/wg-proton.conf.enc
```

The files are encrypted with SOPS using Heighliner's restored/current age identity.

Private keys, provider credentials, preshared keys, and other secret WireGuard configuration remain inside the encrypted artifacts.

They must not be copied into public peer files merely to support recovery.

Before replacing existing recovery state, the capture process should validate that the persistent configuration corresponds to the intended running interface identities.

Use `--force` only when intentionally refreshing existing captured state.

---

### 3. Verify the captured identities

Encrypted configuration can be checked without printing a private key.

For example, the recovered `wg0` identity can be derived with:

```bash
sops --decrypt \
  --input-type json \
  --output-type binary \
  secrets/vps01/wireguard/wg0.conf.enc \
  | awk -F ' = ' '/^PrivateKey = / { print $2; exit }' \
  | wg pubkey
```

The resulting public key should be:

```text
O8SmQdIDV3+SJMldSQoYWV6neF39SPQSz7iMnQGnWz4=
```

Equivalent identity checks can be performed for `wg-pvp` and `wg-proton` without exposing their private keys.

---

### 4. Review and commit

Review the repository normally:

```bash
git status
git diff -- system/vps01/ubuntu
git status --short secrets/vps01/
```

The encrypted WireGuard artifacts are intentionally committed.

Plaintext copies under `/etc/wireguard/` remain local host state.

Once reviewed, commit and push the updated encrypted recovery state and any corresponding non-secret configuration changes.

---

## Applying network reconciliation to the current Heighliner

A full host bootstrap is not required merely to reconcile Heighliner's networking.

Run:

```bash
./system/vps01/ubuntu/configure-system.sh
```

The component order remains:

```text
Wormlogic wg0
        ↓
PVP gateway
```

The setup logic should reconcile an already-running interface without deliberately tearing down working connectivity where `wg syncconf` or an equivalent safe reconciliation path is appropriate.

On a replacement host, the restored configurations are installed under:

```text
/etc/wireguard/
```

and the corresponding systemd/`wg-quick` services bring the interfaces online normally.

---

## Disaster recovery path

On a replacement VPS:

1. Establish the normal administrative user.
2. Set:

   ```text
   ~/.config/dotfiles/machine-id
   ```

   to:

   ```text
   vps01
   ```

3. Clone `linux-environments`.
4. Ensure the provider firewall permits:
   - UDP 51820 for Wormlogic `wg0`
   - UDP 51821 for PVP `wg-pvp`
5. Run the normal `vps01` bootstrap.
6. Bootstrap detects:

   ```text
   secrets/vps01/age-key.age
   ```

   and restores the existing age identity before attempting SOPS recovery.
7. Enter the independently stored age-recovery passphrase.
8. SOPS decrypts:

   ```text
   secrets/vps01/wireguard/wg0.conf.enc
   secrets/vps01/wireguard/wg-pvp.conf.enc
   secrets/vps01/wireguard/wg-proton.conf.enc
   ```

9. The recovered configurations are installed under:

   ```text
   /etc/wireguard/
   ```

10. `wireguard/setup.sh` restores/reconciles Wormlogic `wg0`.
11. `pvp/setup.sh` restores/reconciles `wg-pvp` and `wg-proton`, then applies PVP routing and firewall policy.
12. Complete normal host recovery.
13. Hand application/service recovery to `vps-services`.
14. If the VPS public IP changed, update the public DNS record used by Wormlogic peers.

Existing WireGuard clients retain their configured peer identities because the replacement Heighliner restores the same WireGuard private identities.

---

## PVP design retained

Current PVP architecture:

```text
PVP subnet:   10.9.0.0/24
Heighliner:   10.9.0.1/24
Listener:     UDP 51821
Routing table: 200 (pvp)
Provider VPN: wg-proton
```

Traffic policy remains:

```text
PVP client
    ↓
wg-pvp
    ↓
table 200
    ↓
wg-proton
    ↓
Internet
```

An unreachable fallback remains in table 200 so loss of the provider tunnel does not silently fall back to the VPS's ordinary Internet interface.

Firewall policy permits:

- `wg-pvp → wg-proton`
- approved PVP → private/Wormlogic traffic through `wg0`
- required DNS access to the Heighliner Pi-hole path

Firewall policy blocks:

```text
wg-pvp → ordinary VPS Internet interface
```

NAT applies only to:

```text
10.9.0.0/24 → wg-proton
```

PVP-to-home/private traffic is not NATed.

---

## PVP DNS dependency

The PVP policy depends on the deterministic Pi-hole Docker network owned by `vps-services`:

```text
bridge:        br-pihole
subnet:        172.21.0.0/24
host address:  172.21.0.1
Pi-hole:       172.21.0.2
```

The Docker bridge and Pi-hole container are **not** owned by `linux-environments`.

They remain the responsibility of:

```text
vps-services
```

This creates an intentional dependency boundary:

```text
linux-environments
    ↓
host WireGuard + PVP routing/firewall

vps-services
    ↓
Docker bridge + Pi-hole + application DNS
```

The host bootstrap should not duplicate `vps-services` logic in order to satisfy this dependency.

---

## Still external / not encoded here

The following remain outside `linux-environments` recovery:

- provider firewall rules for UDP 51820 and UDP 51821;
- public DNS failover if the replacement VPS receives a different public IP;
- application/service recovery owned by `vps-services`;
- external provider state associated with the Proton WireGuard profile;
- Midway policy changes that may be required if the PVP routing design changes.

Do not invent or duplicate those authorities inside the host bootstrap.

---

## Obsolete recovery model

The previous split-key recovery model is retired.

Do not use:

```text
secrets/vps01/wg0.key.enc
secrets/vps01/wg-pvp.key.enc
secrets/vps01/wg-proton.conf.enc
```

Do not document recovery as:

```text
private key
    +
tracked public peer configuration
    ↓
reconstruct interface
```

The current model is:

```text
complete persistent interface configuration
        ↓
SOPS-encrypted recovery artifact
        ↓
restore complete interface configuration
```

Once no current script or documentation references the obsolete split-key artifacts, they can be removed from the repository.
