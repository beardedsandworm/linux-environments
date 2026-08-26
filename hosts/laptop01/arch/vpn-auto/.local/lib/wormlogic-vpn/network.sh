#!/usr/bin/env bash
# Shared network identity helpers for Wormlogic VPN automation.
# Sourced by vpn-auto and network-* commands.

vpn_default_route() {
    local route dev gateway family

    route="$(ip -4 route show table main default 2>/dev/null | head -n 1 || true)"
    family="4"

    if [[ -z "$route" ]]; then
        route="$(ip -6 route show table main default 2>/dev/null | head -n 1 || true)"
        family="6"
    fi

    [[ -n "$route" ]] || return 1

    dev="$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$route")"
    gateway="$(awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}' <<<"$route")"

    [[ -n "$dev" ]] || return 1
    printf '%s\t%s\t%s\n' "$dev" "$gateway" "$family"
}

vpn_hash_identity() {
    sha256sum | awk '{print $1}'
}

vpn_iwd_field() {
    local field="$1"
    awk -v field="$field" '
        index($0, field) {
            line=$0
            sub("^.*" field "[[:space:]]+", "", line)
            sub(/[[:space:]]+$/, "", line)
            print line
            exit
        }
    '
}

vpn_wifi_identity() {
    local dev="$1" info state ssid security kind hash

    command -v iwctl >/dev/null 2>&1 || return 1
    info="$(iwctl station "$dev" show 2>/dev/null || true)"
    [[ -n "$info" ]] || return 1

    state="$(vpn_iwd_field 'State' <<<"$info")"
    [[ "$state" == "connected" ]] || return 1

    ssid="$(vpn_iwd_field 'Connected network' <<<"$info")"
    security="$(vpn_iwd_field 'Security' <<<"$info")"
    [[ -n "$ssid" ]] || return 1

    case "$security" in
        *Enterprise*) kind="8021x" ;;
        Open|open|None|none|"") kind="open" ;;
        *) kind="psk" ;;
    esac

    hash="$(printf 'wifi\0%s\0%s' "$kind" "$ssid" | vpn_hash_identity)"
    printf 'wifi:%s\t%s\t%s\twifi\n' "$hash" "$ssid" "$dev"
}

vpn_gateway_mac() {
    local dev="$1" gateway="$2" family="$3" entry mac
    [[ -n "$gateway" ]] || return 1

    entry="$(ip -"$family" neigh get "$gateway" dev "$dev" 2>/dev/null || true)"
    mac="$(awk '{for (i=1;i<=NF;i++) if ($i=="lladdr") {print tolower($(i+1)); exit}}' <<<"$entry")"

    if [[ -z "$mac" ]]; then
        entry="$(ip -"$family" neigh show to "$gateway" dev "$dev" 2>/dev/null | head -n 1 || true)"
        mac="$(awk '{for (i=1;i<=NF;i++) if ($i=="lladdr") {print tolower($(i+1)); exit}}' <<<"$entry")"
    fi

    [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || return 1
    printf '%s\n' "$mac"
}

vpn_ethernet_identity() {
    local dev="$1" gateway="$2" family="$3" mac hash label

    mac="$(vpn_gateway_mac "$dev" "$gateway" "$family" || true)"
    [[ -n "$mac" ]] || return 1

    hash="$(printf 'ethernet\0%s' "$mac" | vpn_hash_identity)"
    if [[ -n "$gateway" ]]; then
        label="Ethernet via $gateway"
    else
        label="Ethernet"
    fi
    printf 'ethernet:%s\t%s\t%s\tethernet\n' "$hash" "$label" "$dev"
}

vpn_current_network() {
    local route dev gateway family
    route="$(vpn_default_route)" || return 1
    IFS=$'\t' read -r dev gateway family <<<"$route"

    # Never classify the VPN interfaces as the underlying network.
    case "$dev" in
        wormlogic|wg-pvp|wg-*) return 1 ;;
    esac

    if [[ -d "/sys/class/net/$dev/wireless" ]]; then
        vpn_wifi_identity "$dev"
        return
    fi

    vpn_ethernet_identity "$dev" "$gateway" "$family"
}

vpn_registry_contains() {
    local file="$1" identity="$2"
    [[ -f "$file" ]] || return 1
    grep -Ev '^[[:space:]]*(#|$)' "$file" | grep -Fxq "$identity"
}

vpn_registry_remove() {
    local file="$1" identity="$2" tmp
    [[ -f "$file" ]] || return 0
    tmp="$(mktemp)"
    awk -v identity="$identity" '$0 != identity' "$file" >"$tmp"
    cat "$tmp" >"$file"
    rm -f "$tmp"
}

vpn_registry_add() {
    local file="$1" identity="$2"
    vpn_registry_contains "$file" "$identity" && return 0
    printf '%s\n' "$identity" >>"$file"
}
