# vps01 secrets

This folder is the recovery home for Heighliner's encrypted device secrets.

Expected files after capture:

- `age-key.age` — the SOPS age private identity encrypted independently with
  `age --passphrase`. Its passphrase MUST live outside Git.
- `wg0.key.enc` — SOPS-encrypted Heighliner Wormlogic wg0 private key.
- `wg-pvp.key.enc` — SOPS-encrypted Heighliner PVP server private key.
- `wg-proton.conf.enc` — SOPS-encrypted complete Proton WireGuard profile.

`age-key.age` deliberately is not SOPS-encrypted; it is the bootstrap recovery
key needed before SOPS can decrypt the other files.
