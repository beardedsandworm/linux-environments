#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles"
N8N_WEBHOOK_FILE="${N8N_WEBHOOK_FILE:-$CONFIG_DIR/n8n-webhook}"
MACHINE_ID_FILE="${MACHINE_ID_FILE:-$CONFIG_DIR/machine-id}"
OUTBOX_DIR="${NOTIFY_OUTBOX_DIR:-$STATE_DIR/notify-outbox}"
DEAD_LETTER_DIR="${NOTIFY_DEAD_LETTER_DIR:-$STATE_DIR/notify-dead-letter}"
SOURCE="linux-environments"

usage() {
  cat <<'EOF'
Usage: notify.sh [options]

Required:
  --producer ID          Stable producer identity
  --kind KIND            observation, incident, or report
  --domain DOMAIN        Semantic domain such as host, storage, or packages
  --event-type TYPE      Stable dotted event type
  --severity LEVEL       info, warning, error, or critical
  --state STATE          observed, open, ongoing, or recovered
  --dedupe-key KEY       Stable lifecycle/deduplication key
  --title TEXT           Short human-readable title
  --summary TEXT         Human-readable summary

Optional:
  --details-json JSON    Structured details object (default: {})
  --event-id ID          Caller-provided idempotency key
  --occurred-at RFC3339  Event timestamp (default: current UTC time)
  --source SOURCE        Source namespace (default: linux-environments)
  -h, --help             Show this help
EOF
}

fail() {
  printf '[notify] ERROR: %s\n' "$*" >&2
  exit 2
}

require_value() {
  [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"
}

producer=""
kind=""
domain=""
event_type=""
severity=""
state=""
dedupe_key=""
title=""
summary=""
details_json="{}"
event_id=""
occurred_at=""

while (($#)); do
  case "$1" in
    --producer) require_value "$@"; producer="$2"; shift 2 ;;
    --kind) require_value "$@"; kind="$2"; shift 2 ;;
    --domain) require_value "$@"; domain="$2"; shift 2 ;;
    --event-type) require_value "$@"; event_type="$2"; shift 2 ;;
    --severity) require_value "$@"; severity="$2"; shift 2 ;;
    --state) require_value "$@"; state="$2"; shift 2 ;;
    --dedupe-key) require_value "$@"; dedupe_key="$2"; shift 2 ;;
    --title) require_value "$@"; title="$2"; shift 2 ;;
    --summary) require_value "$@"; summary="$2"; shift 2 ;;
    --details-json) require_value "$@"; details_json="$2"; shift 2 ;;
    --event-id) require_value "$@"; event_id="$2"; shift 2 ;;
    --occurred-at) require_value "$@"; occurred_at="$2"; shift 2 ;;
    --source) require_value "$@"; SOURCE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

for required in producer kind domain event_type severity state dedupe_key title summary; do
  [[ -n "${!required}" ]] || fail "missing required option: --${required//_/-}"
done

case "$kind" in observation|incident|report) ;; *) fail "invalid kind: $kind" ;; esac
case "$severity" in info|warning|error|critical) ;; *) fail "invalid severity: $severity" ;; esac
case "$state" in observed|open|ongoing|recovered) ;; *) fail "invalid state: $state" ;; esac

command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v flock >/dev/null 2>&1 || fail "flock is required"

[[ -s "$MACHINE_ID_FILE" ]] || fail "machine identity is missing or empty: $MACHINE_ID_FILE"
machine_id="$(tr -d '\r\n[:space:]' <"$MACHINE_ID_FILE")"
[[ -n "$machine_id" ]] || fail "machine identity is empty: $MACHINE_ID_FILE"
hostname_short="$(hostname 2>/dev/null || printf 'unknown-host')"

if [[ -z "$occurred_at" ]]; then
  occurred_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi
if [[ -z "$event_id" ]]; then
  event_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
fi
[[ "$event_id" =~ ^[A-Za-z0-9._:-]+$ ]] || fail "event ID contains unsafe filename characters"

case "$severity" in
  info) legacy_severity="ok" ;;
  warning|error|critical) legacy_severity="$severity" ;;
esac

mkdir -p "$OUTBOX_DIR" "$DEAD_LETTER_DIR"
chmod 700 "$OUTBOX_DIR" "$DEAD_LETTER_DIR"
payload_tmp="$(mktemp "$OUTBOX_DIR/.payload.XXXXXX")"
cleanup() {
  rm -f "$payload_tmp"
}
trap cleanup EXIT

if ! python3 - "$details_json" "$SOURCE" "$producer" "$machine_id" "$hostname_short" \
  "$kind" "$domain" "$event_type" "$severity" "$state" "$dedupe_key" "$title" \
  "$summary" "$event_id" "$occurred_at" "$legacy_severity" >"$payload_tmp" <<'PY'
import json
import sys
from datetime import datetime, timezone

(
    details_raw,
    source,
    producer,
    machine_id,
    hostname,
    kind,
    domain,
    event_type,
    severity,
    state,
    dedupe_key,
    title,
    summary,
    event_id,
    occurred_at,
    legacy_severity,
) = sys.argv[1:]

try:
    details = json.loads(details_raw)
except json.JSONDecodeError as exc:
    raise SystemExit(f"invalid --details-json: {exc}")
if not isinstance(details, dict):
    raise SystemExit("--details-json must decode to an object")

try:
    instant = datetime.fromisoformat(occurred_at.replace("Z", "+00:00"))
except ValueError as exc:
    raise SystemExit(f"invalid --occurred-at: {exc}")
if instant.tzinfo is None:
    raise SystemExit("--occurred-at must include a timezone")
occurred_at = instant.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")

canonical = {
    "event_id": event_id,
    "occurred_at": occurred_at,
    "source": source,
    "producer_id": producer,
    "machine_id": machine_id,
    "hostname": hostname,
    "kind": kind,
    "domain": domain,
    "event_type": event_type,
    "severity": severity,
    "state": state,
    "dedupe_key": dedupe_key,
    "title": title,
    "summary": summary,
    "details": details,
}

# Top-level fields temporarily preserve the current internal n8n webhook contract.
payload = {
    "schema_version": 1,
    "event": canonical,
    "source": source,
    "machine_id": machine_id,
    "hostname": hostname,
    "service": domain,
    "check_name": producer,
    "severity": legacy_severity,
    "title": title,
    "message": summary,
    "timestamp": occurred_at,
}
json.dump(payload, sys.stdout, separators=(",", ":"), sort_keys=True)
sys.stdout.write("\n")
PY
then
  fail "could not build event payload"
fi
chmod 600 "$payload_tmp"

payload_file="$OUTBOX_DIR/$event_id.json"
exec 9>"$OUTBOX_DIR/.lock"
flock 9

if [[ -e "$payload_file" ]]; then
  if ! cmp -s "$payload_tmp" "$payload_file"; then
    fail "event ID already exists with different content: $event_id"
  fi
  rm -f "$payload_tmp"
else
  mv "$payload_tmp" "$payload_file"
fi

[[ -s "$N8N_WEBHOOK_FILE" ]] || {
  printf '[notify] Event %s queued; n8n webhook is missing or empty: %s\n' "$event_id" "$N8N_WEBHOOK_FILE" >&2
  exit 3
}
webhook_url="$(tr -d '\r\n' <"$N8N_WEBHOOK_FILE")"
[[ -n "$webhook_url" ]] || fail "n8n webhook is empty: $N8N_WEBHOOK_FILE"

mapfile -d '' -t queued < <(python3 - "$OUTBOX_DIR" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

items = []
for path in pathlib.Path(sys.argv[1]).glob("*.json"):
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        occurred_at = str(payload.get("event", {}).get("occurred_at", ""))
        instant = datetime.fromisoformat(occurred_at.replace("Z", "+00:00"))
        if instant.tzinfo is None:
            raise ValueError("timestamp has no timezone")
        sort_key = instant.astimezone(timezone.utc).timestamp()
    except (OSError, ValueError, TypeError):
        sort_key = float("inf")
    items.append((sort_key, path.name, path))
for _, _, path in sorted(items):
    sys.stdout.buffer.write(str(path).encode() + b"\0")
PY
)

current_rejected=0
for queued_file in "${queued[@]}"; do
  queued_id="$(basename "$queued_file" .json)"
  response_tmp="$(mktemp "$OUTBOX_DIR/.response.XXXXXX")"
  if http_status="$(curl --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --retry 2 --retry-delay 2 --retry-connrefused \
    --output "$response_tmp" --write-out '%{http_code}' \
    -H 'Content-Type: application/json' \
    -X POST --data-binary "@$queued_file" "$webhook_url")"; then
    case "$http_status" in
      2??)
        rm -f "$queued_file"
        printf '[notify] Delivered event %s for %s (%s)\n' "$queued_id" "$machine_id" "$hostname_short"
        ;;
      400|404|405|410|413|415|422)
        mv -f "$queued_file" "$DEAD_LETTER_DIR/$queued_id.json"
        if [[ "$queued_id" == "$event_id" ]]; then
          current_rejected=1
        fi
        printf '[notify] Event %s was permanently rejected by n8n (HTTP %s) and moved to dead letter\n' "$queued_id" "$http_status" >&2
        ;;
      *)
        rm -f "$response_tmp"
        printf '[notify] Event %s remains queued after transient n8n response HTTP %s\n' "$queued_id" "$http_status" >&2
        exit 75
        ;;
    esac
  else
    rm -f "$response_tmp"
    printf '[notify] Event %s remains queued after n8n transport failure\n' "$queued_id" >&2
    exit 75
  fi
  rm -f "$response_tmp"
done

if ((current_rejected)); then
  exit 65
fi
