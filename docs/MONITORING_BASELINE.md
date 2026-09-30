# Monitoring Baseline

**Repository:** `linux-environments`
**Scope:** Verified monitoring observations followed by the historical host-monitoring baseline and design goals. Service-owned monitors remain authoritative in their own repositories.

## Verified observations — 2026-09-28

- IX runs `internal-dns-monitor.timer`; its sampled service execution returned `Result=success`, `ExecMainStatus=0`, with a healthy/sent journal result. Source authority is `llm-services/services/internal-dns-monitor`, not this host-bootstrap repository.
- The IX monitor is configured for Pi-holes `10.42.20.10` and `.11`. Its `FRESH_RECURSION_SUFFIX` is empty, so its healthy result does not include the optional fresh-recursion diagnostic.
- Heighliner runs the external DNS monitor owned by `vps-services/services/external-dns-monitor`. Its timer was active and its sampled execution succeeded.
- The Heighliner n8n operations REST API returned workflow/execution data; sampled recent executions succeeded. This is not proof of Discord notification delivery. The separate agent-side n8n MCP OAuth connection required renewed authorization at assessment time.
- Home Assistant exposes current Midway/Pi-hole telemetry. A restored/unavailable legacy `WG_GATEWAY` entity was also present; that entity alone does not establish a tunnel outage.
- Beszel hub/agents were visible, but full authenticated hub administration, application backup coverage and restore success were not validated.
- Shai-Hulud, Chapterhouse and Caladan are planned, not deployed: their future addresses are not monitoring availability targets yet. Current network topology is in [NETWORK.md](NETWORK.md).

## Historical baseline and design goals

The sections below record the earlier monitoring baseline and its proposed direction. Claims labelled "Verified", "Current State" or "Current Limitations" within that historical material were not all revalidated in this assessment. In particular, do not infer present notification noise, universal package-update behavior, or the absence of DNS monitoring from the older text.

## Purpose

Monitoring exists to answer one question:

> **Does the homelab require my attention?**

Routine success should increase operational confidence without
generating notifications. Actionable events should notify immediately.

------------------------------------------------------------------------

# Status Classification

-   **Verified** -- Tested and confirmed.
-   **Configured** -- Present but not recently validated.
-   **Planned** -- Intended future work.

------------------------------------------------------------------------

# Current State

## Host Monitoring

### Verified

-   Host monitoring is performed with scheduled scripts.
-   Monitoring results are delivered to Discord.
-   Hosts perform automatic package updates.
-   Basic checks exist for disk usage, heartbeat, and repository
    monitoring.

### Current Limitations

-   Successful checks generate routine notifications.
-   Automatic package updates do not consistently report:
    -   whether updates were applied,
    -   whether updates failed,
    -   whether a reboot is required.
-   Repository synchronization is manual.
-   Monitoring focuses on individual checks rather than operational
    state.
-   There is no overall system health or confidence metric.

------------------------------------------------------------------------

# Desired State

## Design Principles

1.  Silence is success.
2.  Notify only when something changes or requires action.
3.  Every automated task produces a meaningful outcome.
4.  Daily summaries replace repetitive status messages.
5.  Monitoring measures operational readiness rather than script
    execution.

------------------------------------------------------------------------

# Monitoring Categories

## Infrastructure

Track silently:

-   Host availability
-   CPU
-   Memory
-   Disk usage
-   Temperature
-   SMART health
-   Filesystem health

Notify only on threshold violations.

------------------------------------------------------------------------

## Updates

Every automatic update should report:

-   Packages updated
-   Packages skipped
-   Errors
-   Kernel updates
-   Reboot required

Example:

    server01

    8 packages updated

    Kernel updated

    ⚠ Reboot required

No message should be sent if nothing changed.

------------------------------------------------------------------------

## Repository State

Each host should report:

-   Current branch
-   Current commit
-   Remote commit
-   Dirty working tree
-   Automatic pull status

Automatic pulls should occur only when:

-   working tree is clean
-   branch matches expected
-   remote contains newer commits

------------------------------------------------------------------------

## Services

Track:

-   Container health
-   Restart count
-   HTTP availability
-   TLS certificate status
-   Response time

Notify only on changes or failures.

------------------------------------------------------------------------

## Networking

Track:

-   WireGuard handshake age
-   Connected peers
-   DNS resolution
-   VPN availability
-   Internet connectivity

------------------------------------------------------------------------

## Daily Operations Report

Replace multiple routine notifications with a single summary including:

-   Host availability
-   Repository status
-   Package updates
-   Containers
-   VPN
-   Outstanding actions

------------------------------------------------------------------------

# Operational Confidence

Introduce a confidence score representing overall infrastructure health.

Inputs may include:

-   Hosts online
-   Services healthy
-   VPN healthy
-   Repository synchronization
-   Successful backups
-   Pending reboots
-   Failed monitoring tasks

Confidence should decrease only when operational issues are detected.

------------------------------------------------------------------------

# Roadmap

## Phase 1

-   Standardize monitoring output format.
-   Inventory all existing monitoring scripts.
-   Remove routine "success" notifications.
-   Add package update reporting.
-   Detect and report reboot requirements.

## Phase 2

-   Add repository synchronization reporting.
-   Add automatic Git updates for clean repositories.
-   Add WireGuard and DNS health checks.
-   Add service health summaries.

## Phase 3

-   Generate daily operations reports.
-   Introduce operational confidence score.
-   Reduce Discord notifications to actionable events only.

## Long-Term Vision

Monitoring should evolve from a collection of independent scripts into
an operational awareness platform.

Every host contributes telemetry.

Only meaningful operational events generate notifications.

The daily report becomes the primary interface for understanding the
health of the homelab.
