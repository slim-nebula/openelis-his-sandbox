#!/usr/bin/env bash
# =============================================================================
# Monitoring — the collector, the gauges, and whether the alerts can fire
#
# WHY THIS SUITE IS SHAPED THE WAY IT IS
# Monitoring fails silently by nature. A broken alert does not error, it simply
# never fires, and the only symptom is an incident nobody was told about. So
# almost nothing here asserts "the system is healthy" — it asserts that the
# MEASURING APPARATUS is intact:
#
#   * the gauges exist at all (an absent gauge satisfies nothing)
#   * they carry the values the database actually holds
#   * every alert rule parses and evaluates
#   * every metric an alert names EXISTS — the failure where someone renames a
#     gauge, the rule stays "healthy" for ever, and nothing fires again
#
# The last of those is the one no amount of staring at a dashboard would catch.
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

prom() {  # prom <api path> — query Prometheus from inside its container
    docker exec his-prometheus wget -qO- "http://localhost:9090$1" 2>/dev/null
}

prom_value() {  # prom_value <instant query> — the first sample's value, or empty
    prom "/api/v1/query?query=$1" | python3 -c "
import sys,json
try:
    r=json.load(sys.stdin)['data']['result']
    print(r[0]['value'][1] if r else '')
except Exception:
    print('')" 2>/dev/null
}

# ---------------------------------------------------------------------------
section "1 · The collector is running and reaching everything"

check "Prometheus is healthy" \
    "docker exec his-prometheus wget -qO- http://localhost:9090/-/healthy | grep -qi 'healthy\|ok'"

# A target that is DOWN is the honest failure; a target that is MISSING is the
# quiet one — a job removed from the scrape config looks identical to a job
# that never had a problem.
for job in bridge his-api kong; do
    UP=$(prom_value "up%7Bjob%3D%22$job%22%7D")
    [[ "$UP" == "1" ]] \
        && ok "Scraping $job" \
        || bad "Scraping $job" "up{job=\"$job\"} = '${UP:-<no such target>}'"
done

# ---------------------------------------------------------------------------
section "2 · The gauges exist, and are not a reassuring default"

# THE BUG THIS SECTION EXISTS FOR, WHICH WAS MADE WHILE WRITING IT
# prometheus-net registers a gauge at zero. The first version of IntegrationGauges
# had a query Dapper could not materialise, so every refresh threw and all four
# gauges sat at 0 — reading as "nothing stuck, no dead letters, catalogue fresh".
# The most alarming possible state published the most reassuring possible
# numbers, and every alert was satisfied by a component that had never once
# queried the database.
#
# They are therefore unpublished until a refresh succeeds, and ABSENCE is the
# assertion here. A present-but-zero gauge would pass a naive check.
for metric in bridge_oldest_requested_task_age_seconds bridge_dead_letters_total \
              bridge_catalogue_age_seconds bridge_last_poll_age_seconds; do
    V=$(prom_value "$metric")
    [[ -n "$V" ]] \
        && ok "$metric is published ($V)" \
        || bad "$metric is published" "absent — the refresh has never succeeded"
done

# ---------------------------------------------------------------------------
section "3 · The gauges say what the database says"

# A gauge wired to the wrong query is worse than no gauge: it is confidently
# wrong, and it is wrong in the direction of silence. Asserted against the
# database rather than against itself.
DB_DEAD=$(bridge_sql "SELECT count(*) FROM bridge.dead_letters")
GAUGE_DEAD=$(prom_value bridge_dead_letters_total)
[[ "${GAUGE_DEAD%%.*}" == "$DB_DEAD" ]] \
    && ok "Dead-letter gauge matches the table ($DB_DEAD)" \
    || bad "Dead-letter gauge matches the table" "gauge=$GAUGE_DEAD table=$DB_DEAD"

DB_CATALOGUE_AGE=$(bridge_sql "SELECT round(extract(epoch FROM now() - max(synced_at)))
                                 FROM bridge.test_catalogue")
GAUGE_CATALOGUE_AGE=$(prom_value bridge_catalogue_age_seconds)
# Within five minutes: the gauge refreshes on a 30s timer and Prometheus scrapes
# on its own, so an exact match would be asserting the clocks rather than the query.
check "Catalogue-age gauge agrees with the table (within 5 min)" \
    "python3 -c \"
import sys
gauge=float('${GAUGE_CATALOGUE_AGE:-0}'); db=float('${DB_CATALOGUE_AGE:-0}')
assert abs(gauge-db) < 300, f'gauge={gauge} table={db}'\""

# OpenELIS polls every few seconds. A large value here means it has stopped,
# which is the outage this gauge exists to expose; -1 means this bridge process
# has never been polled at all.
POLL_AGE=$(prom_value bridge_last_poll_age_seconds)
check "OpenELIS is polling, and the gauge sees it (${POLL_AGE}s)" \
    "python3 -c \"
v=float('${POLL_AGE:-999999}')
assert v >= 0, 'never polled since this bridge started'
assert v < 300, f'last poll {v}s ago'\""

# ---------------------------------------------------------------------------
section "4 · Every rule parses and evaluates"

# A rule with a syntax error is reported by Prometheus and never evaluated. It
# does not fail loudly; it simply is not there when it is needed.
RULE_HEALTH=$(prom /api/v1/rules | python3 -c "
import sys,json
groups=json.load(sys.stdin)['data']['groups']
bad=[r['name'] for g in groups for r in g['rules'] if r.get('health')!='ok']
print(','.join(bad) if bad else 'ALL_OK')" 2>/dev/null)

[[ "$RULE_HEALTH" == "ALL_OK" ]] \
    && ok "Every alert rule evaluates cleanly" \
    || bad "Every alert rule evaluates cleanly" "unhealthy: $RULE_HEALTH"

RULE_COUNT=$(prom /api/v1/rules | python3 -c "
import sys,json
print(sum(len(g['rules']) for g in json.load(sys.stdin)['data']['groups']))" 2>/dev/null)
check "All seven rules are loaded (found ${RULE_COUNT:-0})" \
    "[[ ${RULE_COUNT:-0} -ge 7 ]]"

# ---------------------------------------------------------------------------
section "5 · Every metric an alert names actually exists"

# THE DEEPEST CHECK HERE, and the one nothing else would catch.
#
# A rule that references a metric which does not exist is perfectly HEALTHY: it
# evaluates, matches nothing, and never fires. Rename a gauge and every alert on
# it goes quiet permanently, with a green rules page. The only way to notice is
# to check that each name still resolves to a series.
MISSING=$(prom /api/v1/rules | python3 -c "
import sys, json, re, urllib.request, urllib.parse

groups = json.load(sys.stdin)['data']['groups']
names = set()
for g in groups:
    for r in g['rules']:
        if r['type'] != 'alerting':
            continue
        # Strip quoted strings BEFORE looking for identifiers.
        #
        # up{component=~\"integration|his\"} otherwise yields 'integration' and
        # 'his' as metric names — they look exactly like bare identifiers once
        # the quotes are ignored — and the check then fails on two series that
        # were never supposed to exist. Label VALUES are data, not metric names.
        expr = re.sub(r'\"[^\"]*\"', '', r['query'])
        # Also drop label-matcher blocks entirely: everything inside {} is a
        # label name or an operator, never a metric.
        expr = re.sub(r'\{[^}]*\}', '', expr)

        for m in re.findall(r'\b([a-zA-Z_][a-zA-Z0-9_]*)\b(?!\s*=)', expr):
            if m in ('increase','rate','absent','up','offset','by','without',
                     'on','group_left','group_right','and','or','unless',
                     'humanizeDuration','component','job','instance','severity'):
                continue
            names.add(m)

missing = []
for n in sorted(names):
    q = urllib.parse.quote(n)
    with urllib.request.urlopen(f'http://localhost:9090/api/v1/query?query={q}') as resp:
        if not json.load(resp)['data']['result']:
            missing.append(n)
print(','.join(missing) if missing else 'NONE')
" 2>/dev/null)

[[ "$MISSING" == "NONE" ]] \
    && ok "Every metric referenced by an alert resolves to a real series" \
    || bad "Every metric referenced by an alert resolves" \
           "no series for: $MISSING — these alerts can never fire"

# ---------------------------------------------------------------------------
section "6 · An alert actually fires when its condition is met"

# Proving the rules are wired, not merely well-formed. Rather than manufacture a
# fault, this reads whichever alert the sandbox's real state satisfies: any
# alert in `pending` or `firing` is the pipeline working end to end — gauge to
# scrape to rule to alert.
#
# If nothing is firing, that is a healthy sandbox rather than a broken suite, so
# it is reported as information and not as a failure.
ACTIVE=$(prom /api/v1/alerts | python3 -c "
import sys,json
a=json.load(sys.stdin)['data']['alerts']
print(' '.join(sorted({x['labels']['alertname']+':'+x['state'] for x in a})) or 'NONE')" 2>/dev/null)

if [[ "$ACTIVE" == "NONE" ]]; then
    info "nothing currently firing — the sandbox is healthy, so the fire path is unproven here"
    ok "Alert API is readable (no active alerts)"
else
    ok "The alert pipeline is live: $ACTIVE"
fi

# The one that must NEVER be firing in a working sandbox: if his-api's consumer
# is down, results are accumulating on the topic and reaching no patient record.
CONSUMER=$(prom_value kafka_consumer_running)
[[ "$CONSUMER" == "1" ]] \
    && ok "The HIS is consuming laboratory results" \
    || bad "The HIS is consuming laboratory results" \
           "kafka_consumer_running = '${CONSUMER:-absent}'"

summary
