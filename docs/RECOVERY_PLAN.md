# Recovery Plan

**Repository:** `linux-environments`  
**Reconciled:** 2026-10-02  
**Scope:** Recovery procedures for systems provisioned by this repository. This document describes the current host-recovery model, remaining gaps, and the target end-to-end recovery workflow.

# Purpose

The objective is to ensure that any managed workstation or server can be rebuilt from documented procedures rather than memory.

Host recovery is successful when a freshly installed system can be returned to its expected host state using the repository, encrypted recovery material, and approved credentials.

Application recovery is a separate layer and remains owned by the corresponding service repository.

# Status Classification

- **Verified** — Tested and confirmed on a deployed system.
- **Configured** — Present in authoritative configuration but not recently exercised end to end.
- **Prepared** — Recovery/provisioning path exists for a machine not yet deployed.
- **Planned** — Intended future work.

# Current Recovery Model

The current host flow is:

1. Install the operating system.
2. Clone `linux-environments`.
3. Run `install.sh` and select the corresponding machine bootstrap.
4. Bootstrap installs prerequisite packages.
5. Bootstrap reconciles the machine `age` identity and SOPS.
6. Bootstrap reconciles SSH credentials and the `linux-environments` deploy key.
7. Bootstrap reconciles Wormlogic WireGuard state where applicable.
8. Bootstrap applies host system configuration, Stow packages, monitoring, and scheduled maintenance.
9. Verify the host.
10. Invoke the service repository's own deployment/recovery process where that host owns services.

Package installation intentionally occurs before encrypted credential recovery because recovery depends on tooling that may not exist on a fresh install.

## Current machine status

- `server01` / Arrakis — deployed; server bootstrap/recovery path aligned.
- `server02` / IX — deployed; server bootstrap/recovery path aligned.
- `server03` / Caladan — prepared, not yet deployed.
- `server04` / Chapterhouse — prepared, not yet deployed; replaces retired `desktop01` preparation.
- `laptop01` — deployed interactive-workstation workflow.
- `laptop02` — deployed and participates in the standardized credential/WireGuard recovery model.
- `vps01` / Heighliner — deployed; host and service recovery still require final ownership/rebuild validation.

# Credential Recovery Model

## age / SOPS root

Each machine has its own age identity.

Live identity:

```text
~/.config/sops/age/keys.txt
```

Encrypted recovery artifact:

```text
secrets/<machine>/age-key.age
```

The bootstrap reconciles local and repository recovery state before depending on SOPS-encrypted machine credentials.

## SSH

Normal device identity:

```text
~/.ssh/id_ed25519
```

Repository-specific deploy key:

```text
~/.ssh/id_ed25519_git_linux-environments
```

Encrypted SSH recovery:

```text
secrets/<machine>/ssh/
```

## Wormlogic WireGuard

Live config:

```text
/etc/wireguard/wormlogic.conf
```

Local staging and derived public key:

```text
~/.config/dotfiles/wireguard/
```

Encrypted authoritative recovery:

```text
secrets/<machine>/wireguard/wormlogic.conf.enc
```

The recovered full configuration contains the peer private key, machine VPN address, and Heighliner peer key.

Generated WireGuard state must not be stored under repository-root `local/`, `.local/`, `share/`, or `shared/` directories.

Prepared server assignments are:

```text
Arrakis      server01   10.8.0.3/32
IX           server02   10.8.0.4/32
Caladan      server03   10.8.0.5/32
Chapterhouse server04   10.8.0.6/32
```

A genuinely new peer identity still requires approval/enrollment on Heighliner.

# Recovery Priorities

Infrastructure should be recovered in dependency order.

## Phase 1 — Administrative Access

Recover an administrative workstation capable of:

- Git access;
- SSH access;
- SOPS/age recovery;
- Wormlogic VPN connectivity.

This workstation becomes the recovery platform.

## Phase 2 — External Administrative Plane

Recover/verify:

- Heighliner;
- Wormlogic WireGuard hub;
- administrative SSH;
- required public-edge services.

Verify remote connectivity before proceeding.

## Phase 3 — Home Network Authority

Recover/verify Midway and the local network dependencies required by the hosts:

- routing/VLANs;
- DHCP;
- Unbound;
- firewall policy;
- local DNS path through the Pi-holes.

Midway configuration is authoritative for network policy; `linux-environments` does not replace the firewall configuration.

## Phase 4 — Core Hosts

Recover hosts in dependency order, beginning with:

- Arrakis (`server01`);
- IX (`server02`);
- other deployed servers as applicable.

For each host, complete host recovery before application recovery.

## Phase 5 — Service Repositories

Use the repository that owns the service:

- `docker-services` for Arrakis;
- `llm-services` for IX;
- `vps-services` for Heighliner;
- `wormlogic-gitops` for Shai-Hulud when deployed.

Service deployment logic should not be duplicated into host bootstraps.

# Verification Checklist

Recovery is complete only after the real capability is tested.

## Host

- Operating system updated.
- Bootstrap completed successfully.
- Repo-specific Git access works.
- Expected Stow configuration is present.
- Scheduled host monitoring/maintenance is enabled.
- Encrypted credential recovery state exists.

## Network

- Wormlogic WireGuard is connected where applicable.
- Expected VPN routes function.
- Intended DNS path resolves.
- Administrative SSH works.
- New peer enrollment has been completed on Heighliner when required.

## Services

- Required service repository is present.
- Local environment/runtime prerequisites can be reconstructed.
- Encrypted service secrets materialize successfully.
- Containers/services are healthy.
- Reverse proxy paths respond where applicable.
- Actual application capability works.

# Current Gaps

The host bootstrap layer is much closer to deterministic recovery, but these gaps remain:

- service-repository cloning and automatic host → service handoff are not complete everywhere;
- ignored environment files such as Arrakis/Heighliner/IX service env files need deterministic reconstruction and validation;
- mutable application data/backups are not yet universally proven restorable;
- Heighliner host networking/boot-order ownership still needs final reconciliation between `linux-environments` and `vps-services`;
- service deployment scripts still contain individual recovery defects identified by the current audit;
- controlled rebuilds have not yet validated every prepared machine;
- a complete infrastructure disaster-recovery exercise has not been performed.

# Desired Future State

A host rebuild should require only:

1. Install the operating system.
2. Clone `linux-environments`.
3. Run the machine bootstrap.
4. Complete any explicitly reported enrollment step such as a newly generated GitHub deploy key or WireGuard peer.
5. Run documented verification.
6. Hand off to the owning service repository.

No undocumented manual host configuration should be required.

Application recovery should similarly be deterministic inside each owning service repository.

# Disaster Recovery Goal

A complete rebuild should be achievable using only:

- repository documentation;
- version-controlled configuration;
- encrypted managed secrets and recovery artifacts;
- approved human credentials;
- application data backups where state is not reproducible.

No recovery step should depend on memory.

# Roadmap

## Phase 1

- Finish environment-file reconstruction/validation.
- Finish server host → service-repository handoff.
- Correct known service deployment defects.
- Reconcile Heighliner host-network ownership.

## Phase 2

- Audit every bootstrap and service deploy path for reproducibility.
- Eliminate undocumented manual steps.
- Align README/baseline documentation with verified behavior.

## Phase 3

- Perform controlled rebuilds of a workstation and deployed server.
- Perform a controlled Heighliner rebuild/recovery exercise.
- Record findings and update documentation.

## Phase 4

- Perform a complete infrastructure recovery exercise.
- Validate service mutable-state restoration.
- Confirm documentation alone is sufficient.

# Success Criteria

The recovery model is considered complete when:

- a new administrative workstation can be provisioned without undocumented steps;
- each deployed host can be reconstructed from its host repository/recovery material;
- each service stack can be reconstructed from its owning repository plus required backups;
- verification confirms real expected operation;
- documentation reflects production rather than retired designs;
- grep/audit of the repository finds no dependency on obsolete repo-root generated credential state.
