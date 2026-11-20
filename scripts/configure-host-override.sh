#!/usr/bin/env bash
set -euo pipefail

TEMPORARY_FILE=""

cleanup() {
  if [[ -n "${TEMPORARY_FILE:-}" ]]; then
    rm -f -- "$TEMPORARY_FILE"
    TEMPORARY_FILE=""
  fi
}

trap cleanup EXIT INT TERM

validate_ipv4() {
  local address="$1"
  local octet
  local -a octets=()

  [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a octets <<< "$address"
  ((${#octets[@]} == 4)) || return 1

  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

validate_hostname() {
  local hostname="$1"

  [[ "$hostname" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  [[ "$hostname" == *.* ]] || return 1
  [[ "$hostname" != *..* ]]
}

rewrite_hosts_file() {
  local input_file="$1"
  local output_file="$2"
  local address="$3"
  local hostname="$4"

  awk -v address="$address" -v hostname="$hostname" '
    BEGIN { OFS = "\t" }

    /^[[:space:]]*($|#)/ {
      print
      next
    }

    {
      original = $0
      data = $0
      comment = ""

      comment_start = match(data, /[[:space:]]+#/)
      if (comment_start) {
        comment = substr(data, RSTART + 1)
        data = substr(data, 1, RSTART - 1)
      }

      sub(/^[[:space:]]+/, "", data)
      sub(/[[:space:]]+$/, "", data)
      field_count = split(data, fields, /[[:space:]]+/)

      if (field_count < 2) {
        print original
        next
      }

      found = 0
      rewritten = fields[1]
      for (field_index = 2; field_index <= field_count; field_index++) {
        if (fields[field_index] == hostname) {
          found = 1
        } else {
          rewritten = rewritten OFS fields[field_index]
        }
      }

      if (!found) {
        print original
        next
      }

      if (rewritten != fields[1]) {
        if (comment != "") {
          print rewritten, comment
        } else {
          print rewritten
        }
      }
    }

    END {
      print address, hostname, "# managed by linux-environments"
    }
  ' "$input_file" > "$output_file"
}

install_host_override() {
  local hosts_file="$1"
  local address="$2"
  local hostname="$3"

  TEMPORARY_FILE="$(mktemp)"
  rewrite_hosts_file "$hosts_file" "$TEMPORARY_FILE" "$address" "$hostname"
  sudo install -o root -g root -m 0644 "$TEMPORARY_FILE" "$hosts_file"
  cleanup

  if [[ "$(getent ahostsv4 "$hostname" | awk 'NR == 1 { print $1 }')" != "$address" ]]; then
    echo "✗ Host override did not resolve as expected: $hostname -> $address" >&2
    return 1
  fi

  echo "✓ Host override ready: $hostname -> $address"
}

main() {
  if (($# != 2)); then
    echo "Usage: $0 <IPv4-address> <hostname>" >&2
    exit 64
  fi

  local address="$1"
  local hostname="$2"

  validate_ipv4 "$address" || {
    echo "✗ Invalid IPv4 address: $address" >&2
    exit 65
  }
  validate_hostname "$hostname" || {
    echo "✗ Invalid hostname: $hostname" >&2
    exit 65
  }

  install_host_override /etc/hosts "$address" "$hostname"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
