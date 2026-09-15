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

# The sync and refresh endpoints change what the hospital can order, so they sit
# behind a bearer token. bridge_admin / his_admin (lib.sh) carry it.
bridge_api() {  # bridge_api <method> <path>
    if [[ $2 == /catalogue/sync* || $2 == /catalogue/syncs* || $2 == /ops/* ]]; then
        bridge_admin "$1" "$2"
    else
        docker exec bridge curl -sS -X "$1" --max-time 600 "http://localhost:8080$2"
    fi
}
his_api() {     # his_api <method> <path>
    if [[ $2 == /admin/* ]]; then
        his_admin "$1" "$2"
    else
        # The menu a doctor orders from is clinical data, so it needs a user
        # token — the same one a clinician's browser would carry.
        docker exec his-api curl -sS -X "$1" --max-time 120 \
            -H "Authorization: Bearer $HIS_TOKEN" "http://localhost:8080$2"
    fi
}

# ---------------------------------------------------------------------------
# The DRIFT fixture below is created by this suite and must not outlive it.
#
# It is a LOINC OpenELIS has never heard of, deliberately, and while it is
# active the smoke suite's "every HIS catalogue LOINC resolves to an OpenELIS
# test" assertion fails. `make rejection` happens to deactivate the same row on
# its way out, so running these two in one order left a clean database and in
# another left a red smoke run — a suite that only passes depending on what ran
# before it is worse than one that fails, because the failure moves.
#
# On EXIT, so section 3 can still assert that a sync leaves the row alone.
cleanup() {
    his_sql "UPDATE his.test_catalogue SET is_active = false
              WHERE test_code = 'DRIFT'" >/dev/null 2>&1
}
trap cleanup EXIT

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

# The invariant is on the PAIR, not the code.
#
# A LOINC may legitimately name several orderable things — 10351-5 is HIV viral
# load on DBS, plasma and serum — and OpenELIS 3.2.2.0 resolves them by the
# sample type the order carries. What must never happen is two ACTIVE tests
# sharing a LOINC *and* a specimen: nothing in an order could separate those, so
# the laboratory would be guessing which bench the specimen goes to.
#
# bridge_rows, not bridge_sql: specimen names contain spaces.
PAIRS=$(bridge_rows "SELECT string_agg('(' || quote_literal(loinc) || ',' ||
                                              quote_literal(specimen_name) || ')', ',')
                       FROM bridge.test_catalogue")

AMBIGUOUS_PAIR=$(oe_sql "
    SELECT coalesce(string_agg(d.loinc || ' on ' || d.specimen, ', '), '')
    FROM (SELECT t.loinc, tos.description AS specimen
            FROM clinlims.test t
            JOIN clinlims.sampletype_test stt ON stt.test_id = t.id
            JOIN clinlims.type_of_sample tos  ON tos.id = stt.sample_type_id
           WHERE (t.loinc, tos.description) IN ($PAIRS)
             AND t.is_active = 'Y'
           GROUP BY t.loinc, tos.description
          HAVING count(DISTINCT t.id) > 1) d")

if [[ -z "$AMBIGUOUS_PAIR" ]]; then
    ok "No offered (LOINC, specimen) resolves to more than one OpenELIS test"
else
    bad "No offered (LOINC, specimen) resolves to more than one OpenELIS test" \
        "shared: $AMBIGUOUS_PAIR — orders for these could go to the wrong bench"
fi

# The specimen we send has to be one OpenELIS recognises, BY NAME.
UNKNOWN_SPECIMEN=$(oe_sql "
    SELECT coalesce(string_agg(p.loinc || ' / ' || p.specimen, ', '), '')
    FROM (VALUES $PAIRS) AS p(loinc, specimen)
    WHERE NOT EXISTS (SELECT 1 FROM clinlims.type_of_sample tos
                       WHERE tos.description = p.specimen)")

if [[ -z "$UNKNOWN_SPECIMEN" ]]; then
    ok "Every offered specimen name matches an OpenELIS sample type exactly"
else
    bad "Every offered specimen name matches an OpenELIS sample type exactly" \
        "unmatched: $UNKNOWN_SPECIMEN"
fi

# THE ABBREVIATION IS WHAT ACTUALLY BINDS, and it is not the name.
#
# The assertion above is necessary but nowhere near sufficient, and believing
# otherwise is what hid this for so long. OpenELIS resolves an order's specimen
# in LabOrderSearchProvider.addToTestOrPanel:
#
#   getTypeOfSampleIdForLocalAbbreviation(code)   <- exact hit on local_abbrev
#   getActiveTestByLoincCodeAndSampleType(loinc, sampleTypeId)
#
# local_abbrev is NOT description: "Whole Blood" is stored as "Whole Bld",
# "Respiratory Swab" as "Resp Swab". A miss returns null and OpenELIS falls
# through to alltests.get(0) — the first active test for the LOINC — logging a
# warning and binding a test nobody ordered. Silent, and wrong in exactly the
# multi-specimen case the per-specimen menu exists to serve.
MISSING_ABBREV=$(bridge_rows "
    SELECT coalesce(string_agg(loinc || ' / ' || specimen_name, ', '), '')
    FROM bridge.test_catalogue
    WHERE specimen_abbrev IS NULL OR specimen_abbrev = ''")

if [[ -z "$MISSING_ABBREV" ]]; then
    ok "Every offered test carries the sample-type abbreviation OpenELIS binds by"
else
    bad "Every offered test carries the sample-type abbreviation OpenELIS binds by" \
        "no abbreviation: $MISSING_ABBREV — orders for these would bind the first test on the LOINC"
fi

# And the abbreviation we cached has to still be the one OpenELIS holds. This is
# the drift that has no other alarm: renaming a sample type's abbreviation in the
# laboratory changes how every order on that specimen binds, with nothing failing.
ABBREV_PAIRS=$(bridge_rows "
    SELECT coalesce(string_agg('(' || quote_literal(specimen_id) || ',' ||
                               quote_literal(specimen_abbrev) || ')', ','), '')
    FROM bridge.test_catalogue WHERE specimen_abbrev IS NOT NULL")

if [[ -n "$ABBREV_PAIRS" ]]; then
    STALE_ABBREV=$(oe_sql "
        SELECT coalesce(string_agg(p.sid || ': ours=' || p.abbrev ||
                                   ' theirs=' || coalesce(tos.local_abbrev,'<gone>'), ', '), '')
        FROM (VALUES $ABBREV_PAIRS) AS p(sid, abbrev)
        LEFT JOIN clinlims.type_of_sample tos ON tos.id::text = p.sid
        WHERE tos.local_abbrev IS DISTINCT FROM p.abbrev")

    if [[ -z "$STALE_ABBREV" ]]; then
        ok "Every cached abbreviation still matches OpenELIS"
    else
        bad "Every cached abbreviation still matches OpenELIS" "drifted: $STALE_ABBREV"
    fi
else
    bad "Every cached abbreviation still matches OpenELIS" "the catalogue cached no abbreviations at all"
fi

# A single OpenELIS TEST must still map to exactly one sample type, even though
# a LOINC may now span several. The two are different things: 10351-5 spans
# three specimens because it names three separate tests, each with one specimen.
# A single test claiming several would be ambiguous again, and this time with
# nothing in the order able to resolve it.
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

# The fixture is created HERE, by this suite, rather than assumed to exist.
#
# It used to be merely asserted, and that made this suite silently depend on
# `make rejection` having run first — that is the only thing that creates DRIFT.
# On a database with history the row was always left over from some earlier run,
# so the dependency was invisible; on a fresh one the assertion simply failed,
# and it failed in a way that looked like a catalogue bug rather than a missing
# fixture. A suite that cannot be run on its own is not a test, it is a ritual.
#
# source = LOCAL is stated, not defaulted: the column defaults to DISCOVERED,
# and a DISCOVERED row is one the sync owns and deactivates as soon as OpenELIS
# stops offering it — which for a LOINC OpenELIS has never heard of is
# immediately. Declaring it is the whole point of the assertion below.
his_sql "INSERT INTO his.test_catalogue
             (test_code, test_name, loinc_code, specimen_type, specimen_snomed,
              result_unit, is_active, source)
         VALUES ('DRIFT', 'Unmapped Drift Test', '99999-9', 'Serum', '119364003',
                 'U/L', true, 'LOCAL')
         ON CONFLICT (test_code) DO UPDATE SET is_active = true, source = 'LOCAL'" >/dev/null

# Re-sync now that the LOCAL row exists, so the assertion tests what it claims:
# that a sync LEAVES IT ALONE, not merely that the row is present.
bridge_api POST /catalogue/sync >/dev/null
his_admin POST /admin/catalogue/refresh >/dev/null

check "DRIFT survives a sync as a LOCAL row" \
    "[[ \$(his_sql \"SELECT count(*) FROM his.test_catalogue WHERE test_code='DRIFT' AND source='LOCAL' AND is_active\") == 1 ]]"

# ---------------------------------------------------------------------------
section "4 · A suspicious sync is refused, not applied"

# The case this guards is not hypothetical: an expired OpenELIS session returns
# an EMPTY LIST rather than an error, and a sync that shrugged that off would
# empty the doctor's menu with one button press.
bridge_sql "INSERT INTO bridge.test_catalogue (loinc, openelis_test_id, name, specimen_name, specimen_id)
            SELECT 'FAKE-'||g, g::text, 'Fixture '||g, 'Serum', '2' FROM generate_series(1,90) g
            ON CONFLICT (loinc, specimen_id) DO NOTHING" >/dev/null
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
