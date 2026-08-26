# Credential Leak Recovery Plan

## Purpose

This document defines the standard recovery process for suspected or confirmed credential exposure anywhere in the lab.

Recovery should be proportional to the scope and severity of the leak.

The objective is to:

- contain the exposure,
- determine exactly what trust boundary has been affected,
- replace credentials that are compromised or reasonably assumed compromised,
- revoke obsolete credentials,
- verify restored operation,
- investigate possible misuse,
- escalate only when higher-level secrets may also have been exposed.

This procedure applies across the lab rather than to any particular machine, repository, or service.

Examples include:

- an API token accidentally committed to Git,
- a database password appearing in logs,
- a `.env` file being exposed,
- a server containing runtime secrets being compromised,
- an SSH private key being lost,
- an `age` private identity being exposed,
- a password being discovered in a third-party breach.

---

# 1. Core Principle: Match Recovery to the Leak

Credential recovery should follow the **smallest defensible trust boundary**.

Do not rotate unrelated credentials simply because an incident occurred.

Examples:

```text
Cloudflare API token leaked
        ↓
Rotate the Cloudflare token
        ↓
Review activity possible with that token
        ↓
No age rotation
```

```text
Application database password leaked
        ↓
Rotate that database credential
        ↓
Review access to that database
        ↓
No unrelated credential rotation
```

```text
Host compromised
        ↓
Identify every secret accessible from that host
        ↓
Rotate those secrets
        ↓
Expand scope only if evidence justifies it
```

```text
age private identity compromised
        ↓
Assume secrets encrypted to that identity may be readable
        ↓
Rotate affected application credentials
        ↓
Replace the age identity
        ↓
Re-encrypt clean state
```

The existence of a credential leak does **not** by itself imply that the encryption system protecting other credentials has failed.

---

# 2. Credential Hierarchy

Different credentials represent different levels of trust.

## Level 1 — Individual Credential

Examples:

- API token
- webhook secret
- database password
- application password
- service token
- individual website password

Compromise normally affects only the permissions granted by that credential.

---

## Level 2 — Account or Service Identity

Examples:

- administrative account
- GitHub account
- Cloudflare account
- SSH private key
- VPN identity
- service account with broad access

Compromise may expose multiple systems accessible through that identity.

Recovery scope should include those systems and any credentials obtainable through them.

---

## Level 3 — Secret-Bearing System

Examples:

- host containing runtime secrets,
- CI/CD runner with injected credentials,
- configuration repository decrypted on an untrusted machine,
- backup containing plaintext secrets,
- automation platform capable of reading many service credentials.

Compromise requires an inventory of **every credential accessible from that system**.

It does not automatically imply compromise of unrelated secret domains.

---

## Level 4 — Secret Protection / Root of Trust

Examples:

- `age` private identity,
- passphrase protecting an `age` private identity,
- unencrypted backup-encryption key,
- KeePass recovery-vault master secret,
- other cryptographic material capable of revealing many credentials.

This is a major escalation.

Compromise may invalidate the confidentiality of an entire secret domain.

Only incidents reaching this level should normally trigger an `age` identity rotation.

---

# 3. General Recovery Workflow

Every credential incident begins with the same initial process.

## Step 1 — Identify the suspected exposure

Record:

- what credential or system may have been exposed,
- when exposure may have occurred,
- how the problem was discovered,
- where the credential existed,
- what the credential authorizes,
- whether related secrets may have been accessible.

Example:

```text
Credential:
    Cloudflare DNS API token

Exposure:
    Token appeared in application logs.

Permissions:
    DNS modification for wormlogic.com.

Initial affected boundary:
    Cloudflare DNS access.
```

---

## Step 2 — Contain the source

Stop further exposure.

Depending on the incident:

- remove exposed files,
- disable public access,
- isolate a compromised host,
- stop a compromised service,
- correct permissions,
- disable a broken CI job,
- stop sensitive values from being logged,
- remove exposed backups or artifacts.

Containment does not make the credential trustworthy again.

---

## Step 3 — Determine the trust boundary

Ask:

- What exactly can this credential access?
- What systems trusted it?
- Could it retrieve other secrets?
- Was it reused?
- Did the affected system contain additional credentials?
- Was cryptographic root material accessible?
- Is there evidence that the incident spread beyond the original credential?

Recovery expands only when the answer to one of these questions justifies expansion.

---

# 4. Classify the Incident

Before rotating credentials, classify the incident.

## A. Single-Credential Exposure

Use when one specific credential leaked and there is no evidence of broader system compromise.

Examples:

- Cloudflare token in logs,
- database password copied into chat,
- webhook secret committed to Git,
- one website password found in a breach.

Proceed to:

**Single-Credential Recovery**

---

## B. Account or Identity Compromise

Use when an attacker may have obtained an identity capable of reaching multiple resources.

Examples:

- SSH private key stolen,
- administrative account compromised,
- GitHub account takeover,
- VPN private key exposed.

Proceed to:

**Account/Identity Recovery**

---

## C. Secret-Bearing System Compromise

Use when a host, container environment, automation system, backup, or similar environment containing multiple secrets may have been accessed.

Proceed to:

**System/Secret-Domain Recovery**

---

## D. Root-of-Trust Compromise

Use when the encryption material used to protect other secrets may itself have been compromised.

Examples:

- `age` private identity exposed,
- `age` identity passphrase exposed together with the identity,
- break-glass vault decrypted by an attacker,
- backup master encryption key exposed.

Proceed to:

**Root-of-Trust Recovery**

This is the only normal workflow that includes `age` identity replacement.

---

# 5. Single-Credential Recovery

Use this workflow for the most common credential leaks.

## Step 1 — Create a replacement

If supported, create the replacement before revoking the old credential.

Example:

```text
Old Cloudflare token
        ↓
Create replacement token
        ↓
Deploy replacement
        ↓
Test
        ↓
Revoke old token
```

If leaving the old credential active creates unacceptable risk, revoke immediately and accept the resulting outage.

---

## Step 2 — Review permissions

Do not blindly reproduce the old credential.

Ask whether the replacement can have:

- narrower permissions,
- access to fewer resources,
- shorter lifetime,
- read-only access,
- more limited scope.

Example:

```text
Instead of:
    Account-wide Cloudflare access

Prefer:
    DNS editing for the required zone only
```

---

## Step 3 — Update authoritative secret storage

Store the replacement where that credential belongs.

Examples:

### Machine/service credential

```text
SOPS + age
```

### Human password

```text
Vaultwarden
```

### Break-glass secret

```text
KeePassXC recovery vault
```

Avoid leaving new credentials in:

- shell history,
- temporary plaintext files,
- notes,
- chat,
- documentation.

---

## Step 4 — Deploy the replacement

Update all consumers of the credential.

Examples:

- Docker services,
- Kubernetes workloads,
- systemd services,
- n8n,
- scripts,
- reverse proxies,
- backup jobs,
- VPS services.

---

## Step 5 — Test the real operation

Do not test merely by checking whether a service started.

Test the capability that requires the credential.

Examples:

```text
Cloudflare token
    → perform DNS operation

Database password
    → authenticate and perform expected query

Backup password
    → restore a test backup

SSH key
    → establish a fresh connection
```

---

## Step 6 — Revoke the old credential

Once the replacement works:

- revoke the token,
- change the password,
- remove the key,
- invalidate the session,
- delete the service credential.

If the credential is merely unused but still valid, recovery is incomplete.

---

## Step 7 — Confirm revocation

Where practical, verify that the old credential fails.

This completes a normal single-credential incident.

### Stop here.

Do **not** rotate:

- unrelated service passwords,
- unrelated repositories,
- `age` identities,
- Vaultwarden credentials,
- backup keys,

unless investigation shows they were also exposed.

---

# 6. Account or Identity Recovery

Use when the compromised item grants access to multiple resources.

Examples:

- administrative user,
- SSH identity,
- GitHub account,
- Cloudflare account,
- VPN identity.

## Step 1 — Secure the identity itself

Depending on the system:

- reset the account password,
- replace the private key,
- rotate MFA credentials if necessary,
- regenerate recovery codes,
- terminate active sessions,
- remove unknown devices,
- revoke unknown OAuth grants.

---

## Step 2 — Inventory reachable systems

Determine what the identity could access.

Example:

```text
Compromised SSH key
        ↓
server01
server02
server03
        ↓
Determine what credentials were readable on each host
```

---

## Step 3 — Expand only where necessary

The compromise of an SSH key does not automatically compromise every secret in the lab.

However, if the key gave root access to a host containing runtime secrets, those runtime secrets should be considered potentially exposed.

Follow the recovery procedure appropriate to each discovered credential.

---

# 7. Secret-Bearing System Recovery

Use when an entire host, runtime environment, automation platform, backup, or similar system may have exposed multiple credentials.

Examples:

```text
/run/secrets/ readable on compromised host
```

```text
n8n credential store compromised
```

```text
decrypted configuration directory copied from workstation
```

## Step 1 — Inventory accessible secrets

Determine what the compromised system actually contained.

Do not simply rotate every credential everywhere.

Build an affected set:

```text
Affected host could access:

    Cloudflare token
    PostgreSQL password
    Home Assistant API token
    webhook secret
```

Those credentials form the immediate rotation scope.

---

## Step 2 — Recover each credential

Apply the Single-Credential Recovery workflow to each item.

Where possible:

```text
Generate
    ↓
Deploy
    ↓
Verify
    ↓
Revoke
```

---

## Step 3 — Determine whether the trust boundary expands

Ask whether the compromised system also contained:

- SSH private keys,
- credentials granting access to additional systems,
- `age` private identities,
- backup encryption keys,
- password-manager recovery information.

If not, the incident stops at the system-secret boundary.

If yes, escalate only to the affected downstream trust domains.

---

# 8. Root-of-Trust / `age` Compromise

This is a separate emergency workflow.

Use it only when an `age` private identity or equivalent root cryptographic material is known or reasonably suspected to have been exposed.

An encrypted SOPS file being exposed **does not constitute an `age` compromise**.

A public `age` recipient being exposed **does not constitute an `age` compromise**.

The sensitive item is the private identity and anything needed to unlock it.

---

## Step 1 — Determine what the identity can decrypt

Identify every secret file encrypted to that recipient.

Example:

```text
docker-services age identity
        ↓
All SOPS secrets encrypted for docker-services
```

Those secrets should now be treated as potentially exposed.

An identity scoped only to `docker-services` should not automatically compromise:

```text
llm-services
vps-services
```

if those domains use independent identities.

This is one reason to maintain separate cryptographic trust domains.

---

## Step 2 — Rotate the secrets exposed through the identity

The attacker may possess historical encrypted copies.

Therefore simply changing the `age` identity is insufficient.

Every sensitive credential encrypted under the compromised identity should be reviewed and rotated.

Examples:

- API tokens,
- database passwords,
- webhook secrets,
- application keys,
- service credentials.

Use the normal credential-rotation workflow for each.

---

## Step 3 — Generate a new `age` identity

Generate a replacement using the standard `age` tooling.

The new private identity should receive a unique strong passphrase.

Store its recovery information in the designated break-glass KeePassXC vault.

---

## Step 4 — Change SOPS recipients

Update the affected secret domain to use the new public recipient.

The public recipient is not sensitive.

---

## Step 5 — Re-encrypt the clean credential state

After application credentials have been rotated:

```text
New application secrets
        ↓
New age identity
        ↓
Re-encrypted SOPS files
```

This establishes a clean cryptographic boundary.

---

## Step 6 — Retire the old identity

Remove the compromised identity from active systems.

Remove its recipient from current encryption configuration.

The old identity should no longer decrypt any **current** secrets.

Historical encrypted files should still be considered compromised because an attacker possessing the old identity can potentially decrypt them.

---

# 9. Example Recovery Scenarios

## Example A — Cloudflare Token Leak

A Cloudflare DNS API token is found in logs.

### Scope

```text
Cloudflare token only
```

### Recovery

```text
Contain log exposure
        ↓
Create new narrowly scoped token
        ↓
Update SOPS secret
        ↓
Deploy Caddy
        ↓
Verify DNS-01 operation
        ↓
Revoke old token
        ↓
Confirm old token fails
```

### Not required

```text
No database password rotation
No age rotation
No Vaultwarden reset
No unrelated service changes
```

---

## Example B — Database Password Exposed

An application database password is accidentally committed to Git.

### Recovery

```text
Remove public exposure where possible
        ↓
Assume password permanently compromised
        ↓
Generate new database password
        ↓
Change database account password
        ↓
Update SOPS secret
        ↓
Redeploy application
        ↓
Verify database operation
        ↓
Confirm old password fails
```

### Not required

No `age` rotation unless the private `age` identity was also exposed.

---

## Example C — Compromised Server

A host is believed to have been accessed as root.

The host contains:

```text
Cloudflare token
database password
webhook token
```

### Recovery

```text
Isolate host
        ↓
Investigate compromise
        ↓
Inventory accessible secrets
        ↓
Rotate those three credentials
        ↓
Verify replacements
        ↓
Revoke originals
```

If the host did **not** contain an `age` private identity:

```text
age remains unchanged
```

If it did contain one:

```text
Escalate to Root-of-Trust Recovery
```

---

## Example D — `age` Private Identity Exposed

The private identity used by `docker-services` is copied to an untrusted system.

### Recovery

```text
Assume docker-services SOPS contents readable
        ↓
Inventory all credentials encrypted to that identity
        ↓
Rotate those credentials
        ↓
Generate new docker-services age identity
        ↓
Store new recovery material in KeePassXC
        ↓
Update SOPS recipient
        ↓
Re-encrypt clean secrets
        ↓
Retire compromised identity
```

Other secret domains using independent identities remain unaffected unless evidence indicates otherwise.

---

# 10. Residual Secret Investigation

For any incident, investigate where copies of the compromised credential may remain.

Possible locations:

- Git history,
- `.env` files,
- shell history,
- logs,
- container logs,
- CI output,
- temporary files,
- backups,
- screenshots,
- documentation,
- retired systems,
- cloud storage.

Remember:

> Removing a credential from the current Git tree does not make a committed credential secret again.

The credential must still be rotated.

Cleaning residual copies reduces future exposure but does not substitute for rotation.

---

# 11. Credential Storage After Recovery

Use the appropriate long-term storage system.

## Vaultwarden

Human-access credentials:

- websites,
- web administration accounts,
- personal accounts,
- routine passwords,
- passkeys/TOTP where appropriate.

---

## SOPS + age

Machine/service credentials:

- API tokens,
- database passwords,
- application secrets,
- webhook tokens,
- container credentials,
- infrastructure configuration secrets.

---

## KeePassXC Break-Glass Vault

Root/recovery material:

- `age` private identities,
- passphrases protecting those identities,
- backup encryption keys,
- Vaultwarden recovery material,
- critical recovery codes.

KeePassXC is the disaster-recovery vault rather than a competing everyday password store.

---

# 12. Recovery Decision Tree

```text
Credential exposure suspected
        │
        ▼
What was exposed?
        │
        ├── One credential
        │       │
        │       └── Rotate that credential
        │
        ├── Account / identity
        │       │
        │       └── Secure identity
        │           + investigate reachable systems
        │
        ├── Secret-bearing system
        │       │
        │       └── Inventory secrets accessible there
        │           + rotate affected secrets
        │
        └── Root cryptographic material
                │
                └── Rotate affected secrets
                    + replace root material
                    + re-encrypt clean state
```

At every stage:

> **Escalate based on evidence and reachable trust, not merely because an incident occurred.**

---

# 13. General Incident Completion Criteria

A normal credential incident is complete when:

- [ ] The source of exposure has been contained.
- [ ] The affected trust boundary has been identified.
- [ ] The compromised credential has been replaced.
- [ ] The replacement has been functionally tested.
- [ ] The old credential has been revoked.
- [ ] Revocation has been confirmed where practical.
- [ ] Relevant logs/activity have been reviewed.
- [ ] Residual copies have been investigated.
- [ ] Any necessary downstream compromises have been handled.
- [ ] Recovery documentation has been updated if the incident revealed a gap.

---

# 14. Additional Criteria for Root-of-Trust Incidents

Only when root cryptographic material was affected:

- [ ] Every secret decryptable by the compromised identity has been reviewed.
- [ ] Credentials requiring rotation have been replaced.
- [ ] A new cryptographic identity has been generated.
- [ ] New recovery material has been stored in the break-glass vault.
- [ ] Current secrets have been encrypted to the new recipient.
- [ ] The compromised identity has been retired.
- [ ] The old identity cannot decrypt current secret state.

---

# Guiding Rule

When recovering from a credential leak:

> **Rotate what was exposed, what the exposed credential could reach, and what evidence shows may have been compromised.**

Do not expand the incident without reason.

A leaked API token is an API-token incident.

A compromised host is a host-and-accessible-secrets incident.

A compromised `age` private identity is a secret-domain incident.

Recovery should become more extensive only as the compromised trust boundary becomes more extensive.