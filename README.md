# 🧠 linux-environments

> Reproducible, recoverable, and observable Linux hosts for the Wormlogic environment.

---

## 💡 Philosophy

> **A machine should be rebuildable from the repository, recoverable from encrypted state, and understandable without relying on memory.**

`linux-environments` is the host-management layer of the Wormlogic infrastructure.

It owns:

* 🖥️ **Host bootstrapping**
* 📦 **Package state**
* 🔗 **Dotfiles and machine-specific configuration**
* 🔐 **Encrypted credential recovery**
* 🔑 **SSH and Git deploy identities**
* 🌐 **Host networking and WireGuard configuration**
* ⚙️ **Systemd services and timers**
* 🔔 **Monitoring and notifications**
* 🧾 **State capture and drift awareness**

Application stacks are intentionally kept in their own repositories.

---

## ⚡ Mental Model

```text
Prepare host + install prerequisites
      ↓
Recover machine identity
      ↓
Restore credentials
      ↓
Apply configuration
      ↓
Enable automation
      ↓
Hand off to service repo
```

Or, operationally:

```text
Define → Recover → Apply → Observe → Correct → Capture
```

* **Define** → packages, host configuration, systemd units
* **Recover** → age, SSH, WireGuard and other durable identities
* **Apply** → bootstrap + Stow + system configuration
* **Observe** → timers, checks and notifications
* **Correct** → update the repository when desired state changes
* **Capture** → preserve recoverable state for the next rebuild

---

## 🖥️ Managed Systems

| Machine | ID | OS | Role | Status |
| --- | --- | --- | --- | --- |
| 💼 Archtop | `laptop01` | Arch | Primary workstation / administration | Deployed |
| 💻 Ubuntop | `laptop02` | Ubuntu | Secondary workstation | Deployed |
| 🐳 Arrakis | `server01` | Ubuntu | Primary Docker host | Deployed |
| 🧠 IX | `server02` | Ubuntu | LLM / agent host | Deployed |
| 💾 Caladan | `server03` | Ubuntu | Storage / services host | Prepared / staged |
| 🎮 Chapterhouse | `server04` | Ubuntu | Shared gaming / streaming / game-service host | Prepared / staged |
| 🚀 Heighliner | `vps01` | Ubuntu | Public VPS / network edge | Deployed |

Each deployed or prepared machine has its own bootstrap path, host configuration, encrypted recovery model and machine identity.

Chapterhouse occupies the `server04` staging path.

---

## 🧩 Repository Structure

```text
linux-environments/
├── install.sh
│
├── hosts/
│   └── <machine>/<os>/
│       └── ...                 # machine-specific Stow packages
│
├── scripts/
│   ├── capture-age-key.sh
│   ├── restore-age-key.sh
│   ├── capture-ssh-credentials.sh
│   ├── restore-ssh-credentials.sh
│   ├── capture-wireguard-credentials.sh
│   ├── restore-wireguard-credentials.sh
│   ├── package-export.sh
│   ├── stow-all.sh
│   └── ...                     # monitoring / installation helpers
│
├── secrets/
│   └── <machine>/
│       ├── age-key.age
│       ├── ssh/
│       └── wireguard/
│
├── stow/
│   └── ...                     # shared user configuration
│
├── system/
│   └── <machine>/<os>/
│       ├── bootstrap.sh
│       ├── apt.txt
│       ├── pacman.txt
│       ├── flatpak.txt
│       ├── snap.txt
│       ├── brew.txt
│       └── ...                 # host-specific system configuration
│
├── systemd/
│   ├── credential-capture.*
│   ├── package-export.*
│   ├── system-update.*
│   ├── repo-update-check.*
│   ├── dotfiles-change-check.*
│   ├── disk-space-check.*
│   ├── heartbeat.*
│   └── ...
│
└── wallpaper/
```

Generated runtime state does **not** belong in the repository.

In particular, the repo must not create ad-hoc top-level `local/`, `.local/`, `share/`, or `shared/` state directories.

---

# 🚀 Recovery and Installation

## New or Rebuilt Machine

The intended recovery path is:

```text
clone linux-environments
        ↓
run install/bootstrap
        ↓
prepare repositories + install prerequisite packages
        ↓
recover or establish machine age identity
        ↓
restore SSH + WireGuard credentials
        ↓
apply host configuration + dotfiles
        ↓
enable systemd automation
        ↓
capture current credential state
        ↓
reboot
        ↓
deploy machine-specific service repository
```

Clone:

```bash
git clone https://github.com/beardedsandworm/linux-environments.git ~/dotfiles
cd ~/dotfiles
./install.sh
```

After initial recovery, the repository is converted to SSH access and bound to the machine's repository-specific GitHub deploy key.

---

# 🆔 Machine Identity

Every managed system has a local machine identifier:

```text
~/.config/dotfiles/machine-id
```

Examples:

```text
laptop01
laptop02
server01
server02
server03
server04
vps01
```

Bootstraps verify this value before applying machine-specific configuration.

This prevents accidentally applying Arrakis configuration to IX, laptop configuration to a server, or another similarly destructive mismatch.

---

# 🔐 Secrets and Recovery

## One age Identity Per Machine

Each machine has its own SOPS/age identity:

```text
~/.config/sops/age/keys.txt
```

That identity is the root of the machine's encrypted recovery state.

An encrypted recovery copy is stored under:

```text
secrets/<machine>/age-key.age
```

The age identity protects recovery of the machine.

Once restored, **SOPS uses that age identity for ordinary encrypted credentials and configuration**.

Ordinary service/API secrets are not stored as standalone raw age-encrypted files.

---

## Credential Reconciliation

Bootstraps use the same basic decision model for recoverable credentials:

```text
Local + Repo
    ↓
Ask which copy is authoritative

Local only
    ↓
Capture into encrypted recovery state

Repo only
    ↓
Restore onto machine

Neither
    ↓
Generate when appropriate, then capture
```

This pattern is used for durable host identities such as:

* age
* SSH
* WireGuard

The bootstrap will not silently replace a missing identity when encrypted state already depends on it.

---

# 🔑 SSH and GitHub Deploy Keys

Each machine keeps its normal SSH identity separate from repository authentication.

Normal machine identity:

```text
~/.ssh/id_ed25519
```

Repository-specific deploy keys use:

```text
~/.ssh/id_ed25519_git_<repository>
```

For `linux-environments`:

```text
~/.ssh/id_ed25519_git_linux-environments
```

Example key comment:

```text
server01:github:linux-environments
```

The repository is bound locally to that key using Git's repository-specific SSH configuration.

This prevents one shared GitHub credential from becoming an implicit dependency across every machine and repository.

---

## SSH Recovery

Current SSH identities are captured into:

```text
secrets/<machine>/ssh/
```

using SOPS + the machine's age identity.

The credential capture process discovers current SSH private identities, including repository-specific deploy keys added later.

That means deploy keys created by service repositories can be picked up by the normal scheduled credential capture process.

---

# 🌐 WireGuard Recovery

Complete WireGuard configurations are captured as encrypted recovery state under:

```text
secrets/<machine>/wireguard/
```

Local staging belongs outside the repository, for example:

```text
~/.config/dotfiles/wireguard/
```

Live configuration belongs under:

```text
/etc/wireguard/
```

The repository should not generate plaintext WireGuard state into arbitrary repo-root directories.

---

## Wormlogic VPN

The Wormlogic WireGuard network provides remote connectivity between managed systems.

Configured Wormlogic VPN identities include:

```text
Heighliner    10.8.0.1
Midway        10.8.0.2
Arrakis       10.8.0.3
IX            10.8.0.4
Caladan       10.8.0.5   # prepared / staged
Chapterhouse  10.8.0.6   # prepared / staged
laptop01      10.8.0.10
laptop02      10.8.0.11
```

Prepared assignments are part of the recovery/bootstrap plan; they do not imply that the peer is already enrolled on Heighliner or currently reachable.

The home network is routed as:

```text
10.42.0.0/16
```

Machine bootstraps restore or configure the appropriate peer state rather than relying on undocumented manual setup.

---

# 📦 Package State

Machine package declarations live under:

```text
system/<machine>/<os>/
```

Depending on the platform:

```text
apt.txt
pacman.txt
flatpak.txt
snap.txt
brew.txt
```

These files describe the desired software baseline for each system.

Package export automation also records the current installed state so drift can be reviewed rather than guessed.

---

# 🔗 Configuration Ownership

Shared user configuration:

```text
stow/
```

Machine-specific configuration:

```text
hosts/<machine>/<os>/
```

Host bootstrap and system configuration:

```text
system/<machine>/<os>/
```

Encrypted machine recovery state:

```text
secrets/<machine>/
```

Transient or generated runtime state belongs outside Git.

---

# ⚙️ Automation

Managed hosts run a common set of user-level systemd services and timers.

Typical automation includes:

| Automation | Purpose |
| --- | --- |
| `credential-capture` | Capture encrypted credential recovery state |
| `package-export` | Record installed package state |
| `system-update` | Scheduled host maintenance |
| `repo-update-check` | Detect remote repository changes |
| `dotfiles-change-check` | Detect local configuration drift |
| `disk-space-check` | Warn about storage pressure |
| `heartbeat` | Confirm that the machine is alive |

Machine-specific services may also be installed where required.

---

# 🔔 Observability

The machines are expected to report their own state instead of requiring constant manual inspection.

Monitoring covers areas such as:

* package state
* repository drift
* dotfile drift
* disk usage
* system updates
* credential capture
* host availability
* service-specific health where appropriate

Notifications can be delivered through the Wormlogic Discord/n8n monitoring path.

The objective is not merely:

```text
"Is the machine running?"
```

but:

```text
"Is it running the way the repository says it should?"
```

---

# 🐳 Service Repository Boundary

`linux-environments` owns the **host**.

It does not own every application running on that host.

Current major service repositories include:

| Host | Service Repository | Responsibility |
| --- | --- | --- |
| Arrakis | `docker-services` | Primary Docker application stack |
| IX | `llm-services` | Hermes / agent / LLM services |
| Heighliner | `vps-services` | VPS-hosted services |
| Shai-Hulud | `wormlogic-gitops` | Talos / Kubernetes / Flux state |

Caladan and Chapterhouse are currently staged at the host layer; their final service-repository ownership should be documented when those deployments become active.

The desired recovery pattern is:

```text
linux-environments
       ↓
recover and configure host
       ↓
service repository
       ↓
deploy applications
```

Service-specific Docker Compose files, runtime preparation, application secrets and deployment logic belong in their owning service repository.

The host bootstrap may clone or invoke those repositories, but should not duplicate their internal deployment logic.

---

# 🛠️ Repository-Owned Deployments

Service repositories are moving toward a common deployment model:

```text
decrypt secrets
      ↓
prepare runtime state
      ↓
build required images
      ↓
start services
      ↓
install monitoring
      ↓
install repo-specific host integration
      ↓
generate / verify GitHub deploy key
      ↓
capture credentials
```

This keeps recovery predictable while preserving clear ownership between host configuration and application deployment.

---

# 🔄 Recovery Goal

The long-term recovery experience is intentionally simple:

```text
git clone linux-environments
cd linux-environments
./install.sh
```

From there, the system should be able to:

1. identify the machine
2. prepare package repositories and install prerequisite software
3. establish or recover its age identity
4. recover SSH credentials
5. recover host networking
6. apply user and host configuration
7. install monitoring and maintenance timers
8. prepare repository authentication
9. invoke the appropriate service deployment path
10. capture the resulting durable credentials
11. reboot into a fully recovered system

Manual steps should exist only where human authorization is actually required.

---

# 🧠 Design Rules

A few rules keep the repository predictable:

* **Host configuration belongs here.**
* **Application deployment belongs to the application repo.**
* **Secrets are encrypted at rest.**
* **Each machine has its own age identity.**
* **Each repository gets its own deploy key.**
* **Generated runtime state does not belong in Git.**
* **Recovery paths are tested infrastructure, not documentation-only theory.**
* **Bootstraps should be safe to rerun.**
* **Machine identity is verified before machine-specific changes are applied.**
* **Current state should be observable and capturable.**

---

# 📌 Summary

`linux-environments` is the recovery and configuration layer for the Wormlogic Linux fleet.

It provides:

* 🔁 reproducible host builds
* 🧱 encrypted recovery state
* 🔐 SOPS + age credential management
* 🔑 per-repository GitHub deploy identities
* 🌐 recoverable WireGuard configuration
* 📦 declared package state
* 🔗 shared and machine-specific dotfiles
* ⚙️ scheduled host automation
* 🔔 monitoring and drift awareness
* 🐳 clean handoff to service repositories

The goal is simple:

> **A failed machine should be an inconvenience, not an archaeological project.**

---

## 🧑‍💻 Author

Matthew J Garry
