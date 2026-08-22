#!/usr/bin/env bash
# Shared helpers for the sandbox test scripts.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a

API="http://localhost:${EDGE_HTTP_PORT}/api"

PASS=0
FAIL=0

# --- Signing in ---------------------------------------------------------------
# The clinical API is behind the estate's user token, so a suite has to sign in
# the same way a clinician does. Minted once per run rather than per request:
# the estate stores ONE session per user, so a second sign-in for the same user
# ends the first — two tokens minted mid-suite would revoke each other.
#
# Minted only if the sandbox is up, because several scripts source this file
# with nothing running and must not fail here.
HIS_TOKEN="${HIS_TOKEN:-}"
if [[ -z "$HIS_TOKEN" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx his-api; then
    HIS_TOKEN=$("$ROOT/scripts/mint-token.sh" --quiet --user 1 --name suite.runner \
        ${LAB_ORDER_GROUP:+--groups "$LAB_ORDER_GROUP"} 2>/dev/null) || HIS_TOKEN=""
fi
export HIS_TOKEN

# curl as a signed-in user. Use these for anything under /api that reads or
# writes patient data; /health and /metrics answer without a credential and can
# use plain curl.
api_curl()   { curl -H "Authorization: Bearer $HIS_TOKEN" "$@"; }
api_status() { curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $HIS_TOKEN" "$@"; }

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
dim()   { printf '\033[2m%s\033[0m' "$1"; }

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

ok()   { PASS=$((PASS+1)); printf '  [%s] %s\n' "$(green PASS)" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [%s] %s\n' "$(red FAIL)" "$1"; [[ $# -gt 1 ]] && printf '        %s\n' "$2"; return 0; }
info() { printf '  %s\n' "$(dim "$1")"; }

# check "<description>" "<command>"  — passes when the command exits 0
check() {
    local description="$1" command="$2" output
    if output=$(eval "$command" 2>&1); then
        ok "$description"
    else
        bad "$description" "${output:0:400}"
    fi
}

# check_contains "<description>" "<command>" "<expected substring>"
check_contains() {
    local description="$1" command="$2" expected="$3" output
    output=$(eval "$command" 2>&1)
    if [[ "$output" == *"$expected"* ]]; then
        ok "$description"
    else
        bad "$description" "expected to find '$expected' in: ${output:0:400}"
    fi
}

# Runs psql inside the HIS database container and echoes a single value.
his_sql() {
    docker exec -e PGPASSWORD="$HIS_DB_PASSWORD" his-db-external \
        psql -tAX -U "$HIS_DB_USER" -d "$HIS_DB_NAME" -c "$1" 2>/dev/null | tr -d '[:space:]'
}

# Same, but preserves whitespace and newlines — use for multi-row output.
his_rows() {
    docker exec -e PGPASSWORD="$HIS_DB_PASSWORD" his-db-external \
        psql -tAX -U "$HIS_DB_USER" -d "$HIS_DB_NAME" -c "$1" 2>/dev/null
}

oe_sql() {
    docker exec -e PGPASSWORD="$OE_DB_PASSWORD" openelis-db-external \
        psql -tAX -U "$OE_DB_USER" -d "$OE_DB_NAME" -c "$1" 2>/dev/null | tr -d '[:space:]'
}

bridge_sql() {
    docker exec -e PGPASSWORD="$BRIDGE_DB_PASSWORD" his-db-external \
        psql -tAX -U "$BRIDGE_DB_USER" -d "$BRIDGE_DB_NAME" -c "$1" 2>/dev/null | tr -d '[:space:]'
}

# Curl from inside the sandbox network, for services that publish no host port.
in_sandbox() {
    docker exec bridge curl -fsS --max-time 10 "$1" 2>/dev/null
}

# The bridge's and the HIS service's administrative endpoints need a bearer
# token. Centralised here so a suite cannot accidentally exercise the
# unauthenticated path and report a pass on a 401 body it never parsed.
#
#   bridge_admin <method> <path> [extra curl args...]
bridge_admin() {
    local method="$1" path="$2"; shift 2
    docker exec bridge curl -sS -X "$method" --max-time 600 \
        -H "Authorization: Bearer $BRIDGE_ADMIN_TOKEN" "$@" "http://localhost:8080$path"
}

his_admin() {
    local method="$1" path="$2"; shift 2
    docker exec his-api curl -sS -X "$method" --max-time 120 \
        -H "Authorization: Bearer $HIS_ADMIN_TOKEN" "$@" "http://localhost:8080$path"
}

# HTTP status only, from a named container, with whatever headers are passed.
# Used to assert that a door is shut, which needs the code and not the body.
http_status() {  # http_status <container> <method> <url> [curl args...]
    local container="$1" method="$2" url="$3"; shift 3
    docker exec "$container" curl -s -o /dev/null -w '%{http_code}' \
        -X "$method" --max-time 30 "$@" "$url" 2>/dev/null
}

json_field() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)" 2>/dev/null; }

# Any test the HIS will currently accept an order for.
#
# Use this wherever a test only needs to be orderable and the particular analyte
# is irrelevant. Hardcoding a code couples the test to a catalogue that is now
# discovered from OpenELIS and changes when the laboratory changes: ALT and PLT
# stopped being orderable the moment discovery noticed their LOINC codes are
# each shared by two tests, and every suite that named them broke at once with
# an empty response body.
any_active_test_code() {
    his_sql "SELECT test_code FROM his.test_catalogue
             WHERE is_active AND source = 'DISCOVERED'
             ORDER BY test_code LIMIT 1"
}

summary() {
    printf '\n────────────────────────────────────────\n'
    printf '  %s passed, %s failed\n' "$(green "$PASS")" "$( [[ $FAIL -eq 0 ]] && green "$FAIL" || red "$FAIL")"
    printf '────────────────────────────────────────\n'
    [[ $FAIL -eq 0 ]]
}
