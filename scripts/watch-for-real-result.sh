#!/usr/bin/env bash
# Waits for the FIRST DiagnosticReport that OpenELIS itself produces, ignoring
# any already in the bridge's mirror (those are simulated by test-result-return).
# Writes the id to /tmp/real_dr.txt when it lands.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE=$(bridge_sql "SELECT coalesce(string_agg(resource_id, ','),'') FROM bridge.received_resources WHERE resource_type='DiagnosticReport'")
echo "baseline: $(tr ',' '\n' <<< "$BASE" | grep -c .) existing DiagnosticReport(s), watching for a new one"

for _ in $(seq 1 "${WATCH_ITERATIONS:-360}"); do
    NEW=$(bridge_sql "SELECT resource_id FROM bridge.received_resources
                      WHERE resource_type='DiagnosticReport'
                        AND resource_id <> ALL (string_to_array('$BASE', ','))
                      ORDER BY received_at DESC LIMIT 1")
    if [[ -n "$NEW" ]]; then
        echo "REAL_DR=$NEW" | tee /tmp/real_dr.txt
        exit 0
    fi
    sleep 10
done

echo "TIMEOUT" | tee /tmp/real_dr.txt
exit 1
