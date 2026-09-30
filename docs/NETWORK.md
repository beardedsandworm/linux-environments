# Network

**Repository:** `linux-environments`
**Verified:** 2026-09-28
**Scope:** Current logical topology, observed infrastructure addresses, DNS and administrative access. This is a documented snapshot, not a replacement for Midway's live configuration.

## Authority and status

Midway owns routing, VLAN interfaces, DHCP, firewall policy, Unbound and the home VPN topology. Host network configuration and service-repository definitions supply the corresponding host/container evidence. Address or policy changes must be reconciled with those authorities rather than made only in this document.

- **Verified:** corroborated by live state or a successful functional check on the date above.
- **Configured:** present in authoritative configuration; not proof of end-to-end client behavior.
- **Planned:** owner-confirmed future infrastructure, not an unavailable deployed host.

The former flat `10.42.42.0/24` description is obsolete. That subnet remains in use as **TRUSTED**, one zone in the segmented network.

## Segmented LAN

The following VLAN interfaces and connected routes are present on Midway. All use the `igb0` trunk; VLAN tag and OPNsense interface name are distinct identifiers.

| Zone | VLAN tag | Interface | Subnet | Gateway |
|---|---:|---|---|---|
| MGMT | 10 | `vlan01` | `10.42.10.0/24` | `10.42.10.1` |
| SERVERS | 20 | `vlan02` | `10.42.20.0/24` | `10.42.20.1` |
| CLUSTER | 25 | `vlan03` | `10.42.25.0/24` | `10.42.25.1` |
| IOT | 30 | `vlan04` | `10.42.30.0/24` | `10.42.30.1` |
| FABRICATION | 32 | `vlan05` | `10.42.32.0/24` | `10.42.32.1` |
| ENTERTAINMENT | 35 | `vlan06` | `10.42.35.0/24` | `10.42.35.1` |
| GUEST | 40 | `vlan07` | `10.42.40.0/24` | `10.42.40.1` |
| TRUSTED | 42 | `vlan09` | `10.42.42.0/24` | `10.42.42.1` |
| SECURITY | 50 | `vlan08` | `10.42.50.0/24` | `10.42.50.1` |

Midway also has **LOCAL_DNS**, `10.42.254.53/32`, on `lo1`. This is a resolver endpoint, not a client VLAN.

WAN uses `igb1` and the ISP default route. WAN has IPv6, while the inspected VLAN IPv6 address settings are empty; this document does not assert an operational routed IPv6 design for those VLANs.

### DHCP

Kea DHCPv4 configuration covers the nine VLANs. Each subnet advertises:

- DNS: `10.42.20.10` and `10.42.20.11`;
- router: that subnet's `.1` address;
- NTP: that subnet's `.1` address.

The configured dynamic pool is `.101–.250` in MGMT, SERVERS, CLUSTER, IOT, FABRICATION, ENTERTAINMENT, GUEST and SECURITY. TRUSTED's pool field is empty in the inspected configuration; do not infer an old `.100–.200` pool or claim DHCP lease acquisition was tested from that field alone.

These are configuration observations. Full DHCP acquisition from a client in each VLAN was not exercised.

## Deployed infrastructure

| System | Current address | Verified role / access |
|---|---|---|
| Midway | VLAN `.1` gateways; LOCAL_DNS `10.42.254.53`; VPN `10.8.0.2` | OPNsense router/firewall, DHCP and Unbound; SSH at `10.42.20.1` |
| Arrakis (`server01`) | `10.42.20.4`; VPN `10.8.0.3` | Docker application host, Home Assistant and internal Caddy reverse proxy; SSH works |
| IX (`server02`) | `10.42.20.5`; VPN `10.8.0.4` | Hermes/Ollama runtime host; SSH works |
| Pi-hole 1 | `10.42.20.10` | Physical resolver; SSH and DNS work |
| Pi-hole 2 | `10.42.20.11` | Arrakis macvlan container; DNS works |
| Heighliner (`vps01`, hostname `wormlogic-vps01`) | `10.8.0.1`; administrative hostname `vpn.wormlogic.com` | VPS, WireGuard hub and operations services; SSH works |
| Existing media workstation (`lightweight-pc.` in DHCP) | `10.42.42.3` | Live host observed by Midway; Arrakis media proxy routes target it. Individual media application health was not established |

Arrakis has a host-side Pi-hole macvlan shim at `10.42.20.100/32`, with a route to `10.42.20.11`. It is host/container connectivity plumbing, not another Pi-hole instance.

Configured Omada infrastructure addresses are `10.42.10.3`, `.4`, `.5` and `.10` for the switch/AP reservations. These reservations were read from Midway; individual device administration was not validated.

### Planned systems — not deployed

The owner confirms **Shai-Hulud, Chapterhouse and Caladan do not yet exist as deployed infrastructure**. Their configured future targets are:

| Planned system | Configured future address / reservation |
|---|---|
| Chapterhouse | `10.42.20.3` |
| Caladan | `10.42.20.6` |
| Shai-Hulud control reservation | `10.42.25.3` (`kube_cont01`) |
| Shai-Hulud worker reservations | `10.42.25.4–6` (`kube_work01–03`) |

The CLUSTER VLAN exists; a deployed cluster does not. Do not classify these planned hosts as down or assume credentials, workloads, storage or cluster services exist. The old `.42.50–53` cluster reservation description is superseded by the configured CLUSTER addresses above.

## DNS

The current home-client DNS path is:

```text
client
  → Pi-hole 1 (10.42.20.10) or Pi-hole 2 (10.42.20.11)
  → Midway Unbound LOCAL_DNS (10.42.254.53:53)
  → Quad9 DNS-over-TLS through Proton
```

Both Pi-hole configurations specify `10.42.254.53#53` as upstream and have blocking active. Pi-hole-level DNSSEC is disabled; validation is enabled at Midway Unbound.

Configured DoT upstreams are:

- `9.9.9.9:853`;
- `149.112.112.112:853`;
- TLS authentication name: `dns.quad9.net`.

Midway's live routes send both Quad9 addresses through Proton on `wg1`. Certificate-verified TLS connections to both upstreams succeeded during the assessment. The old localhost `53053` forwarding entry is disabled.

From IX, both Pi-holes answered UDP/TCP queries, blocked the tested gravity fixture, and returned SERVFAIL for `dnssec-failed.org`. IX's host resolver lists the Pi-hole pair; Hermes uses Docker's `127.0.0.11` resolver backed by the host resolver.

### DNS policy and observation boundary

Configured firewall policy allows client DNS to the Pi-holes, allows Pi-hole forwarding to Midway, and blocks other routed TCP/UDP 53 and TCP 853 traffic on the relevant local rule path. An ordinary client should not use direct Midway queries as its DNS health test. IX-to-Midway direct DNS timed out while the intended Pi-hole path worked.

This is not a claim that all DNS-over-HTTPS traffic on 443 is blocked, or that Midway controls traffic remaining on the same L2 segment. Loaded PF rules and enforcement from every client VLAN were not attested.

## WireGuard and administrative access

The administrative network is `10.8.0.0/24`:

| Address | Verified system |
|---|---|
| `10.8.0.1` | Heighliner |
| `10.8.0.2` | Midway |
| `10.8.0.3` | Arrakis |
| `10.8.0.4` | IX |

Arrakis is a service host and VPN peer, **not the home gateway**. Midway holds that role. Heighliner also hosts the `10.9.0.0/24` PVP VPN network; Midway has a route for that subnet through its `wormlogic` tunnel. This document does not assert that every VPN client has identical access.

Midway has a `10.42.0.0/16` route through `wg0`, alongside the more-specific connected VLAN `/24` routes. The connected VLAN routes take precedence; unassigned portions of the aggregate can follow the VPN. The Proton tunnel is separate from the administrative tunnel.

SSH key authentication to `vpn.wormlogic.com` and the deployed LAN hosts listed above was verified. The assessment used existing identities and verified host keys; no passwords or private keys belong in this document. Laptop VPN assignments are omitted from the verified table because they were not independently revalidated in this pass.

### Segmentation policy status

Midway's **current configuration includes TRUSTED in `ALL_NETS`**, independently rechecked after the owner's correction. The previous TRUSTED omission is resolved at the configuration level.

Configured aliases have different scopes: `ALL_NETS` includes all nine VLAN network references plus `WORM_NET` (`10.8.0.0/24`); `REMOTE_ADMINS` contains `10.8.0.0/24` and `10.9.0.0/24`. Read alias contents and ordered rules together rather than assuming an alias name proves its coverage. This documentation update did not change policy or validate compiled PF enforcement.

## Private service names and reverse proxies

Service DNS names need not identify the physical service host. Verified examples:

| Name | Resolution / ownership |
|---|---|
| `search.wormlogic.com` | Arrakis `10.42.20.4`, Caddy to SearXNG |
| `automate.wormlogic.com` | Arrakis `10.42.20.4`, Caddy to the Arrakis n8n instance |
| `ix.wormlogic.com` | Arrakis `10.42.20.4`, Caddy to IX `10.42.20.5:9119` |
| `ops.wormlogic.com` | `10.8.0.1` from the tested home runtime; Heighliner Caddy/n8n operations plane |

On Heighliner, `ops.wormlogic.com` intentionally resolves locally to `127.0.0.1` through a host mapping. Its recovery requirement is documented in `vps-services/docs/OPS_LOCAL_RESOLUTION.md`.

`automate.wormlogic.com` and `ops.wormlogic.com` are separate n8n deployments. Do not infer duplication or migration completion from a shared application name.

## Docker-network boundaries relevant to operations

- IX publishes Hermes ports on `10.42.20.5`; its Homepage Docker proxy binds `10.42.20.5:2375`.
- Heighliner's Homepage Docker proxy binds `10.8.0.1:2375`.
- Arrakis's Homepage Docker proxy is internal to its Compose Docker network, not host-published.
- The proxies disable mutating methods in configuration, but allowed container-inspect GET responses can contain environment credentials. Read-only is not equivalent to secret-safe.
- Arrakis Home Assistant and Matter Server use host networking; Pi-hole 2 uses macvlan. Application deployment details remain owned by the service repositories.

## Verification sources and limits

Reconciliation used:

- allowlisted fields from Midway `/conf/config.xml` for VLANs, aliases, DHCP options, Unbound and VPN configuration;
- `ifconfig`, `netstat -rn -f inet`, and route inspection;
- native host `ip -br addr`, `ip route`, `resolvectl dns` and authenticated SSH identity checks;
- Pi-hole configuration fields, bounded `dig` queries and TLS checks;
- selective Docker inspection, Caddy routes and hostname resolution;
- the owner's explicit classification of planned systems.

Examples of harmless client-side checks:

```sh
resolvectl dns
ip route
dig @10.42.20.10 example.com A +time=2 +tries=1
dig @10.42.20.11 example.com A +tcp +time=2 +tries=1
```

On Midway, use approved read access for topology and configuration. Some generated Unbound/Kea files and loaded PF state require additional permission; their absence from an unprivileged view is not evidence of service failure. No switch-port audit, all-VLAN reachability matrix, VPN failover test or complete public-exposure audit was performed.
