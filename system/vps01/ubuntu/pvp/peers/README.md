# wg-pvp peers

The current public peer definitions are intentionally captured from the live
Heighliner by `scripts/capture-vps01-wireguard-state.sh`.

That script writes `current.conf` in this directory, excluding dynamic
`Endpoint=` lines and refusing to export a plaintext `PresharedKey=`.

Commit the resulting public peer file after reviewing it. On disaster recovery,
`pvp/setup.sh` assembles `/etc/wireguard/wg-pvp.conf` from the encrypted
`secrets/vps01/wg-pvp.key.enc` identity plus the committed peer definition(s).
