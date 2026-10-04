# vps01 secrets

This directory is the encrypted recovery home for **Heighliner** (`vps01`) machine-specific secrets owned by `linux-environments`.

It contains the material required to recover the host's age identity and WireGuard configuration after a rebuild.

## Expected layout

```text
secrets/vps01/
├── age-key.age
└── wireguard/
    ├── wg0.conf.enc
    ├── wg-pvp.conf.enc
    └── wg-proton.conf.enc
```

## Age identity

```text
age-key.age
```

is the recovery copy of Heighliner's SOPS age private identity.

Unlike ordinary machine secrets, this file is encrypted directly with:

```text
age --passphrase
```

rather than SOPS.

This is intentional: the machine's age identity must be recoverable **before** SOPS can decrypt any of the other encrypted artifacts in this directory.

The passphrase for `age-key.age` must remain outside Git.

Once restored, the live age identity belongs at:

```text
~/.config/sops/age/keys.txt
```

## WireGuard recovery

Heighliner's WireGuard recovery authority is the set of **complete encrypted interface configurations** under:

```text
secrets/vps01/wireguard/
```

Current interfaces are:

```text
wg0.conf.enc
wg-pvp.conf.enc
wg-proton.conf.enc
```

These are SOPS-encrypted copies of the complete WireGuard configurations required by the host.

The recovery model is therefore:

```text
secrets/vps01/wireguard/*.conf.enc
        ↓
restore with Heighliner's age identity
        ↓
/etc/wireguard/*.conf
```

Do not maintain separate recovery artifacts for individual WireGuard private keys.

Older split-key artifacts such as:

```text
wg0.key.enc
wg-pvp.key.enc
```

are obsolete and are not part of the current recovery model.

## Ownership

`linux-environments` owns:

- Heighliner's age identity recovery
- host SSH credential recovery
- WireGuard configuration recovery
- machine bootstrap and host configuration

Service credentials belong to their owning service repositories instead.

For Heighliner, application/service secrets are owned by:

```text
vps-services
```

and should not be duplicated here.

## Recovery order

A bare-host recovery follows this general sequence:

```text
restore age-key.age
        ↓
install age identity
        ↓
decrypt WireGuard configuration
        ↓
restore /etc/wireguard/
        ↓
restore remaining host credentials
        ↓
complete host bootstrap
        ↓
hand off to vps-services
```

The age identity is therefore the root of the encrypted machine-recovery chain.

## Security rules

- Never commit plaintext WireGuard configuration.
- Never commit plaintext age private keys.
- Never store the `age-key.age` passphrase in this repository.
- Do not create additional one-off encrypted secret formats when SOPS with Heighliner's age identity can be used.
- Keep application/service secrets in their owning service repositories rather than under `linux-environments`.
