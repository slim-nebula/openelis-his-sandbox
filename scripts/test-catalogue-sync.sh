#!/usr/bin/env bash
# =============================================================================
# Catalogue discovery — filters, guards and the HIS mirror
#
# The HIS test menu is no longer written by hand: the bridge asks OpenELIS which
# tests it will actually accept an order for, and the HIS mirrors the answer.
#
# The filters are the dangerous part. A test that slips through them looks
# perfectly ordinary on the ordering screen and then stalls at the accessioning
# screen, because OpenELIS cannot bind an order whose LOINC resolves to two
# tests or whose test accepts two specimens. That failure is invisible from the
# HIS side, which is exactly why it went unnoticed for so long the first time.
#
# So rather than trust the filter, this checks every offered test against
# OpenELIS's own tables. Reading both databases is fine HERE - a test harness
# sits outside the architectural boundary that forbids the running services from
# doing it, and checking one system's claim against another's records is the
# whole point.
#
#   scripts/test-catalogue-sync.sh
# =============================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

bridge_api() {  # bridge_api <method> <path>
    docker exec bridge curl -sS -X "$1" --max-time 600 "http://localhost:8080$2"
}
his_api() {     # his_api <method> <path>
    docker exec his-api curl -sS -X "$1" --max-time 120 "http://localhost:8080$2"
}

# ---------------------------------------------------------------------------
section "1 · The menu is served from cache, with its age"

CATALOGUE=$(bridge_api GET /catalogue)
COUNT=$(echo "$CATALOGUE" | json_field "['count']")
SYNCED=$(echo "$CATALOGUE" | json_field "['syncedAt']")

if [[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -gt 0 ]]; then
    ok "The bridge is offering $COUNT tests"
else
    bad "The bridge is offering tests" "count was '$COUNT' — run 'make sync-catalogue' first"
    summary; exit 1
fi

check "The menu reports when it was last synced" "[[ '$SYNCED' != 'None' && -n '$SYNCED' ]]"

# ---------------------------------------------------------------------------
section "2 · Every offered test is one OpenELIS can actually bind"

# This is the assertion that would have caught the original defect on day one.
LOINCS=$(bridge_sql "SELECT string_agg(quote_literal(loinc), ',') FROM bridge.test_catalogue")

AMBIGUOUS_LOINC=$(oe_sql "
    SELECT coalesce(string_agg(loinc, ', '), '')
    FROM (SELECT t.loinc FROM clinlims.test t
           WHERE t.loinc IN ($LOINCS) AND t.is_active = 'Y'
           GROUP BY t.loinc HAVING count(*) > 1) d")

if [[ -z "$AMBIGUOUS_LOINC" ]]; then
    ok "No offered LOINC resolves to more than one OpenELIS test"
else
    bad "No offered LOINC resolves to more than one OpenELIS test" \
        "shared: $AMBIGUOUS_LOINC — orders for these would stall at accessioning"
fi

# The other half of the same guarantee. OpenELIS does not use the Specimen we
# send to narrow a multi-specimen test, so one specimen per test is required and
# not merely preferred.
MULTI_SPECIMEN=$(oe_sql "
    SELECT coalesce(string_agg(d.description, ', '), '')
    FROM (SELECT t.description
            FROM clinlims.test t
           WHERE t.loinc IN ($LOINCS) AND t.is_active = 'Y'
             AND (SELECT count(*) FROM clinlims.sampletype_test st WHERE st.test_id = t.id) <> 1) d")

if [[ -z "$MULTI_SPECIMEN" ]]; then
    ok "Every offered test accepts exactly one specimen"
else
    bad "Every offered test accepts exactly one specimen" "multi-specimen: $MULTI_SPECIMEN"
fi

# An order can only be placed for a test that exists to be matched.
UNKNOWN=$(oe_sql "
    SELECT coalesce(string_agg(l.loinc, ', '), '')
    FROM (VALUES $(bridge_sql "SELECT string_agg('(' || quote_literal(loinc) || ')', ',') FROM bridge.test_catalogue")) AS l(loinc)
    WHERE NOT EXISTS (SELECT 1 FROM clinlims.test t WHERE t.loinc = l.loinc AND t.is_active = 'Y')")

if [[ -z "$UNKNOWN" ]]; then
    ok "Every offered LOINC matches an active OpenELIS test"
else
    bad "Every offered LOINC matches an active OpenELIS test" \
        "not in the matcher: $UNKNOWN — these orders would be rejected"
fi

# ---------------------------------------------------------------------------
section "3 · The HIS mirrors the bridge, and forgets nothing"

check "The HIS offers exactly what the bridge discovered" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.test_catalogue WHERE is_active AND source='DISCOVERED'\") == $COUNT ]]"

# The two catalogues live in separate databases and cannot be joined, so compare
# the sets in the harness. Counting alone would pass even if the HIS mirrored a
# completely different 25 tests.
BRIDGE_LOINCS=$(bridge_sql "SELECT string_agg(loinc, ',' ORDER BY loinc) FROM bridge.test_catalogue")
HIS_LOINCS=$(his_sql "SELECT string_agg(loinc_code, ',' ORDER BY loinc_code)
                      FROM his.test_catalogue WHERE is_active AND source='DISCOVERED'")
if [[ "$BRIDGE_LOINCS" == "$HIS_LOINCS" ]]; then
    ok "The HIS mirrors the same LOINC codes, not merely the same number"
else
    bad "The HIS mirrors the same LOINC codes, not merely the same number" \
        "bridge and HIS disagree on which tests are offered"
fi

# The specimen has to travel too: it is what the order asks the laboratory to
# collect, and a stale one produces an order the LIS will not bind.
SPECIMEN_DRIFT=$(his_sql "SELECT count(*) FROM his.test_catalogue
                          WHERE is_active AND source='DISCOVERED' AND coalesce(specimen_type,'') = ''")
check "Every mirrored test carries a specimen" "[[ '$SPECIMEN_DRIFT' == 0 ]]"

# Deactivated rather than deleted. An order placed last year must still say what
# test it was for, and lab_orders.test_code has a foreign key into this table.
ORPHANS=$(his_sql "SELECT count(*) FROM his.lab_orders o
                    WHERE NOT EXISTS (SELECT 1 FROM his.test_catalogue c WHERE c.test_code = o.test_code)")
check "No historical order lost the test it refers to" "[[ '$ORPHANS' == 0 ]]"

check "DRIFT survives a sync as a LOCAL row" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.test_catalogue WHERE test_code='DRIFT' AND source='LOCAL'\") == 1 ]]"

# ---------------------------------------------------------------------------
section "4 · A suspicious sync is refused, not applied"

# The case this guards is not hypothetical: an expired OpenELIS session returns
# an EMPTY LIST rather than an error, and a sync that shrugged that off would
# empty the doctor's menu with one button press.
bridge_sql "INSERT INTO bridge.test_catalogue (loinc, openelis_test_id, name, specimen_name, specimen_id)
            SELECT 'FAKE-'||g, g::text, 'Fixture '||g, 'Serum', '2' FROM generate_series(1,90) g
            ON CONFLICT (loinc) DO NOTHING" >/dev/null
INFLATED=$(bridge_sql "SELECT count(*) FROM bridge.test_catalogue")
info "inflated the cached menu to $INFLATED so a real sync looks like a collapse"

REFUSED=$(bridge_api POST /catalogue/sync)
check "The sync refuses to shrink the menu that far" \
    "[[ \$(echo '$REFUSED' | json_field \"['applied']\") == False ]]"
check "It says why, so the operator can decide" \
    "[[ -n \$(echo '$REFUSED' | json_field \"['reason']\") ]]"
check "And the cached menu is left exactly as it was" \
    "[[ \$(bridge_sql 'SELECT count(*) FROM bridge.test_catalogue') == $INFLATED ]]"

FORCED=$(bridge_api POST "/catalogue/sync?force=true")
check "force applies it deliberately" \
    "[[ \$(echo '$FORCED' | json_field \"['applied']\") == True ]]"
check "The fixtures are gone and the real menu is back" \
    "[[ \$(bridge_sql \"SELECT count(*) FROM bridge.test_catalogue WHERE loinc LIKE 'FAKE-%'\") == 0 ]]"

# ---------------------------------------------------------------------------
section "5 · The HIS refuses an empty menu too"

# Two independent guards. The bridge's protects against a bad read from
# OpenELIS; this one protects against a freshly deployed bridge with nothing
# synced yet, which would otherwise deactivate every test in the HIS.
HIS_BEFORE=$(his_sql "SELECT count(*) FROM his.test_catalogue WHERE is_active AND source='DISCOVERED'")
bridge_sql "DELETE FROM bridge.test_catalogue" >/dev/null

EMPTY_REFRESH=$(his_api POST /admin/catalogue/refresh)
check "Refreshing from an empty bridge is refused" \
    "[[ \$(echo '$EMPTY_REFRESH' | json_field \"['applied']\") == False ]]"
check "The HIS menu is untouched by the refusal" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.test_catalogue WHERE is_active AND source='DISCOVERED'\") == $HIS_BEFORE ]]"

# ---------------------------------------------------------------------------
section "6 · Put it back"

bridge_api POST /catalogue/sync >/dev/null
his_api POST /admin/catalogue/refresh >/dev/null
RESTORED=$(bridge_sql "SELECT count(*) FROM bridge.test_catalogue")
check "A normal sync restores the menu" "[[ '$RESTORED' == '$COUNT' ]]"
check "And the HIS matches it again" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.test_catalogue WHERE is_active AND source='DISCOVERED'\") == $COUNT ]]"

summary
