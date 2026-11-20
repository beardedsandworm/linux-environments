# Operational Baseline

**Repository:** `linux-environments`  
**Verified / reconciled:** 2026-10-02  
**Scope:** Current host-provisioning, administrative-access, credential-recovery, and repository-ownership baseline. Live configuration remains authoritative where noted.

## Status Classification

- **Verified** — Tested and confirmed on a deployed system.
- **Configured** — Present in authoritative configuration but not necessarily exercised end to end.
- **Prepared** — Provisioning/recovery path exists for a machine that is not yet deployed.
- **Planned** — Intended future infrastructure or workflow.
- **Retired** — No longer part of the supported design.

## 1. Infrastructure authority

- Midway is the home router, firewall, DHCP and Unbound authority.
- Arrakis (`server01`) is a service host and Wormlogic WireGuard peer, not the LAN gateway.
- The home network is segmented into nine VLANs. `10.42.42.0/24` is TRUSTED, not the entire LAN.
- Current VLAN, DNS, address, and VPN topology is documented in [NETWORK.md](NETWORK.md).
- Host operating-system configuration and recovery belong to `linux-environments`.
- Application/service deployment logic belongs to the repository that owns those services.

## 2. Managed systems

| Machine | Identity | Status | Wormlogic VPN |
|---|---|---|---|
| Arrakis | `server01` | Verified deployed host | `10.8.0.3/32` |
| IX | `server02` | Verified deployed host | `10.8.0.4/32` |
| Caladan | `server03` | Prepared, not yet deployed | `10.8.0.5/32` |
| Chapterhouse | `server04` | Prepared, not yet deployed | `10.8.0.6/32` |
| laptop01 | workstation | Deployed | existing client identity; assignment should be read from live/recovery state |
| laptop02 | workstation | Deployed | `10.8.0.11/32` |
| Heighliner | `vps01` | Verified deployed host | `10.8.0.1/24` hub |
| Midway | firewall/router | Verified deployed infrastructure | `10.8.0.2` |

`desktop01` is retired as a provisioning target. Chapterhouse preparation now uses `server04`.

Shai-Hulud remains planned infrastructure. Caladan and Chapterhouse have prepared host identities/bootstrap paths but are not yet production availability targets.

## 3. Host bootstrap model

Server bootstraps follow this order:

1. Verify machine identity and operating system.
2. Prepare package repositories and install/update required packages.
3. Reconcile the machine `age` identity and ensure SOPS is available.
4. Reconcile SSH identities and the `linux-environments` repo-specific deploy key.
5. Reconcile Wormlogic WireGuard recovery state.
6. Apply host environment/system configuration.
7. Configure scheduled host maintenance and monitoring.
8. Apply Stow-managed host configuration.
9. Perform host-specific verification and report any remaining operator action.

Package installation intentionally precedes credential recovery because the recovery helpers depend on packages such as `age`, `sops`, OpenSSH, and WireGuard tooling.

## 4. Credential and recovery ownership

### SOPS + age

Each machine has its own `age` identity.

Plaintext identity:

```text
~/.config/sops/age/keys.txt
```

Encrypted recovery artifact:

```text
secrets/<machine>/age-key.age
```

The machine identity is the root needed to decrypt that machine's SOPS-protected recovery material.

### SSH

The normal machine SSH identity remains:

```text
~/.ssh/id_ed25519
```

`linux-environments` uses a repository-specific GitHub deploy key:

```text
~/.ssh/id_ed25519_git_linux-environments
```

Encrypted SSH recovery artifacts live under:

```text
secrets/<machine>/ssh/
```

### WireGuard

The supported Wormlogic peer model is:

```text
live system config
  /etc/wireguard/wormlogic.conf

local staging / derived public key
  ~/.config/dotfiles/wireguard/

encrypted authoritative recovery
  secrets/<machine>/wireguard/wormlogic.conf.enc
```

A recovered full WireGuard configuration is sufficient to recover the peer identity, assigned VPN address, and Heighliner peer key.

Generated WireGuard state does **not** belong under repository-root `local/`, `.local/`, `share/`, `shared/`, or equivalent scratch directories.

When no local or encrypted recovery copy exists, the bootstrap may generate a new peer identity, install the completed configuration, capture it into encrypted recovery, and display the peer block that must be approved on Heighliner.

## 5. Administrative VPN topology

The administrative WireGuard network is `10.8.0.0/24`.

Current/deployment-prepared assignments relevant to the server fleet are:

```text
10.8.0.1   Heighliner
10.8.0.2   Midway
10.8.0.3   Arrakis
10.8.0.4   IX
10.8.0.5   Caladan       (prepared)
10.8.0.6   Chapterhouse  (prepared)
10.8.0.11  laptop02
```

Peer enrollment on Heighliner remains an explicit approval step when a new peer identity is created.

The Proton tunnel is separate from the Wormlogic administrative VPN and must not be conflated with host peer recovery.

## 6. Repository boundaries

### `linux-environments`

Owns:

- machine bootstrap and operating-system preparation;
- host package state;
- host Stow configuration;
- machine credential recovery;
- host WireGuard client configuration;
- host systemd user timers/services;
- host-level boot/network integration where applicable.

### Service repositories

Own their own application deployment logic and service secrets, for example:

- `docker-services` — Arrakis services;
- `llm-services` — IX agent/runtime services;
- `vps-services` — Heighliner services;
- `wormlogic-gitops` — Shai-Hulud Kubernetes state.

Host bootstraps should prepare the machine and hand off to repo-owned installers rather than duplicate service logic.

## 7. Monitoring baseline

Host monitoring includes package export, system updates, repository checks, disk-space checks and scheduled credential capture where the corresponding units exist.

The monitoring design rule remains:

> **Silence is success.**

Routine success should be logged locally; notifications should represent changes or actionable conditions. Service-repository image-update checks still require remediation where they currently emit success notifications for the no-update case.

See [MONITORING_BASELINE.md](MONITORING_BASELINE.md) for the broader monitoring model.

## 8. Current recovery gaps

The host credential-recovery model is substantially standardized, but infrastructure recovery is not complete until the following are also deterministic:

- service-repository cloning and host → service handoff;
- required ignored environment-file reconstruction and validation;
- service-owned mutable-state backup/restore;
- complete Heighliner host-network/boot-order ownership reconciliation;
- controlled rebuild testing for each machine class;
- end-to-end disaster-recovery exercises.

## 9. Verification expectations

A host is not considered recovered merely because the bootstrap exits successfully.

Verify as applicable:

- repository access using the repo-specific deploy key;
- SSH access;
- Wormlogic WireGuard handshake and routing;
- expected DNS path;
- host timers/monitoring;
- Docker/GPU/runtime prerequisites;
- service-repository deployment;
- actual application capability.

## 10. Guiding rule

`linux-environments` should be sufficient to reconstruct the **host** without relying on undocumented operator memory.

Local runtime/scratch state belongs outside the repository. Recoverable credentials belong in the established encrypted per-machine recovery paths. Application logic remains with the repository that owns the application.
