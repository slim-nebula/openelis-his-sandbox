#!/usr/bin/env bash
# =============================================================================
# Does the billing map still describe the laboratory's menu?
#
# The map is deployment configuration; the menu is synced from OpenELIS. They
# drift on their own, and the drift is SILENT in the direction that costs money:
# the laboratory enables a test, nobody prices it, a doctor orders it, the
# laboratory runs it, and the hospital never bills for it. Nothing errors.
#
# Run this after every `make sync-catalogue`, and as a deployment gate.
# Exits non-zero only when a test is orderable and unmapped, because that is
# the case where work gets done for free. Orphans and shared charge items are
# reported and do not fail: both are legitimate often enough that failing on
# them would teach people to ignore the check.
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib.sh"

# lib.sh has pass/fail and nothing between. These findings are neither: they
# need a human decision, and failing on them would teach people to ignore the
# check — which is how a check stops being read at all.
warn() { printf '  [%s] %s\n' "$(printf '\033[33mNOTE\033[0m')" "$1"; }

section "Billing map vs the laboratory's menu"

REPORT=$(his_sql "
  SELECT json_build_object(
    'orderable', (SELECT count(*) FROM his.test_catalogue WHERE is_active),
    'mapped',    (SELECT count(*) FROM his.test_catalogue c
                    JOIN his.lab_billing_map m
                      ON m.loinc_code = c.loinc_code AND m.specimen_type = c.specimen_type
                   WHERE c.is_active AND m.is_active),
    'no_claim',  (SELECT count(*) FROM his.lab_billing_map WHERE is_active AND claim_code IS NULL)
  )::text")

ORDERABLE=$(python3 -c "import sys,json;print(json.loads(sys.argv[1])['orderable'])" "$REPORT")
MAPPED=$(python3    -c "import sys,json;print(json.loads(sys.argv[1])['mapped'])"    "$REPORT")
NOCLAIM=$(python3   -c "import sys,json;print(json.loads(sys.argv[1])['no_claim'])"  "$REPORT")

info "$MAPPED of $ORDERABLE orderable tests carry a billing mapping"

# --- The one that fails the check -------------------------------------------
UNMAPPED=$(his_rows "
  SELECT '    ' || c.test_name || '  [' || c.specimen_type || ']  ' || c.loinc_code
    FROM his.test_catalogue c
    LEFT JOIN his.lab_billing_map m
      ON m.loinc_code = c.loinc_code AND m.specimen_type = c.specimen_type AND m.is_active
   WHERE c.is_active AND m.loinc_code IS NULL
   ORDER BY c.test_name, c.specimen_type")

if [[ -n "$UNMAPPED" ]]; then
    bad "Every orderable test has a billing mapping" \
        "$(echo "$UNMAPPED" | wc -l | tr -d ' ') orderable test(s) cannot be billed"
    echo "$UNMAPPED"
    echo
    echo "    A doctor can order these today. The laboratory will run them."
    echo "    Nobody will be charged, and nothing will report an error."
else
    ok "Every orderable test has a billing mapping"
fi

# --- Reported, never fatal ---------------------------------------------------
ORPHANED=$(his_rows "
  SELECT '    ' || m.loinc_code || '  [' || m.specimen_type || ']  -> ' || m.charge_item_ref
    FROM his.lab_billing_map m
    JOIN his.test_catalogue c
      ON c.loinc_code = m.loinc_code AND c.specimen_type = m.specimen_type
   WHERE NOT c.is_active OR NOT m.is_active
   ORDER BY m.loinc_code")

if [[ -n "$ORPHANED" ]]; then
    warn "Mapped, but the laboratory no longer offers it"
    echo "$ORPHANED"
    echo "    Harmless — no new order can reach them. Decide whether the charge"
    echo "    item retires too."
else
    ok "No mapping points at a withdrawn test"
fi

SHARED=$(his_rows "
  SELECT '    ' || m.charge_item_ref || '  covers  ' ||
         string_agg(m.loinc_code || ' [' || m.specimen_type || ']', ', ' ORDER BY m.loinc_code)
    FROM his.lab_billing_map m
   WHERE m.is_active
   GROUP BY m.charge_item_ref
  HAVING count(*) > 1")

if [[ -n "$SHARED" ]]; then
    warn "One charge item covers several tests"
    echo "$SHARED"
    echo "    Correct for a panel, or for specimens priced the same."
    echo "    Wrong if it is a copy-paste in the deployment spreadsheet — only"
    echo "    the hospital can tell which, so this never fails the check."
else
    ok "Each charge item covers exactly one test"
fi

if [[ "$NOCLAIM" -gt 0 ]]; then
    warn "$NOCLAIM mapped test(s) carry no claim code"
    echo "    Legitimate for cash-only work. If these are claimed against a"
    echo "    payer, the claim has nothing to say the procedure was."
else
    ok "Every mapped test carries a claim code"
fi

summary
