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
