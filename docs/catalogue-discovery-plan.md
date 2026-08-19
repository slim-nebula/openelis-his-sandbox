# Plan — let the HIS discover its test menu from OpenELIS

**Status:** proposed, not started. Written 2026-08-18 for the next working session.

## Goal

The doctor's test dropdown in the HIS should show exactly the tests the laboratory
has switched on in OpenELIS — no more, no less — without anyone maintaining a list
by hand on either side.

## Why this matters

Today `his.test_catalogue` is a hand-written table of seven tests whose LOINC codes
were chosen by guessing at OpenELIS's catalogue. That produced two failures that
cost most of a session to diagnose:

* Four tests resolved to an OpenELIS test accepting several specimens, and two
  resolved to a LOINC code shared by two different tests. In both cases OpenELIS
  refused to bind the order, and the accessioning screen made the technician pick
  the test by hand on every single order.
* The HIS asked for Serum on three tests where OpenELIS expected Plasma or Whole
  Blood. Nothing detected the disagreement, because nothing compared the two lists.

Both are symptoms of the same thing: **two independent catalogues that can drift.**
Discovery removes the second catalogue rather than trying to keep it in step.

It also removes the need for the OpenELIS database edits made in this session —
see Phase 0. That matters for a deployment where the LIS is subject to laboratory
accreditation: the integration should read OpenELIS, never reshape it.

## Verified facts — do not re-derive these

All confirmed by direct HTTP call against the running 3.2.1.11 sandbox on
2026-08-18. Base URL `https://localhost/api/OpenELIS-Global`.

### Authentication

`/rest/*` endpoints need a form-login session cookie:

```
GET  /LoginPage                      -> scrape name="_csrf" value="..."
POST /ValidateLogin                  loginName, password, _csrf   -> 302
GET  /session                        -> { authenticated: true, csrf: "<token>" }
```

The legacy `ajaxQueryXML` servlet additionally needs that token as an
`X-CSRF-Token` header; the `/rest/*` catalogue endpoints do not.

### The catalogue endpoints

```
GET /rest/test-catalog/tests?page=1&pageSize=250
    -> { page, pageSize, total: 210, rows: [ {
           testId, name, code, domain,
           active, sampleType, sampleTypes: [...],
           hasLoinc,                       // boolean only, not the code
           findings: [...], errorCount, warningCount, infoCount
         } ] }

GET /rest/test-catalog/tests/{id}/basic-info
    -> { testId, name, code, description, domain, labUnitId,
         sampleTypeId, sampleTypeIds: [...],
         active: true, orderable: true }   // <- the "lab switched it on" flag

GET /rest/test-catalog/tests/{id}/terminology
    -> { testId,
         mappings:    [ { source: "LOINC", code: "718-7", relationship: "SAME_AS" } ],
         components:  [ ... ],
         sampleTypes: [ { id: "4", name: "Whole Blood", domain: "CLINICAL" } ] }
```

`hasLoinc` is on the list row, but the LOINC **code** is only on
`/terminology`. That drives the call-volume question below.

Shape of this instance today:

```
210 tests total
201 active
 60 carry a LOINC code
 54 active + LOINC + exactly one specimen     <- the safely orderable set
```

`findings` is OpenELIS's own catalogue quality checker (95 rows carry findings,
e.g. `TERMINOLOGY_NO_DISPLAY_NAME`). Worth surfacing later; not needed for v1.

### Endpoints checked and rejected

| Endpoint | Why not |
|---|---|
| `/rest/test-sample-types` | 400, needs an undocumented parameter |
| `/rest/sample-type-tests` | 500 |
| `/rest/test-display-beans` | returns an empty list |

## Phase 0 — put OpenELIS back to seed state

Do this first. It is the reason the rest of the plan is worth doing, and it must
be verified before anything depends on the new behaviour.

This session modified `clinlims` to force our seven tests to be unambiguous. Once
discovery is in place those edits are unnecessary, because ambiguous tests simply
never reach the dropdown. Revert them exactly:

```sql
BEGIN;

-- Duplicate LOINC codes cleared by 01-loinc-mapping.sql
UPDATE clinlims.test SET loinc = '1742-6' WHERE id = 1;    -- GPT ALAT(Serum)
UPDATE clinlims.test SET loinc = '777-3'  WHERE id = 20;   -- Platelets(Whole Blood)

-- The five specimen bindings it deleted, with their original ids/display_order
INSERT INTO clinlims.sampletype_test (id, sample_type_id, test_id, is_panel, display_order)
VALUES (255, 2, 15, false, NULL),   -- Serum  on Hemoglobin Bld
       (261, 2,  3, false, NULL),   -- Serum  on Glucose
       (3,   3,  3, false, 1),      -- Plasma on Glucose
       (4,   2,  4, false, 3),      -- Serum  on Creatinine
       (7,   2,  7, false, 5)       -- Serum  on Total Cholesterol
    ON CONFLICT (id) DO NOTHING;

COMMIT;
```

Then delete `openelis/provision/01-loinc-mapping.sql`, drop the `provision`
target from the Makefile, and restart the webapp — sample-type bindings are
cached in memory, so the revert is invisible until it restarts.

Full pre-change dump, if the targeted revert is ever in doubt:
`scratchpad/backup-20260818-210627/clinlims.sql`.

**Verify:** `LabOrderSearchProvider` for an HGB order should go back to returning
`crosstests` instead of `sampleTypes`. That regression is expected and correct —
after Phase 2, HGB is simply no longer offered to the doctor.

Leave `site_information 'external orders' = true` alone. It is set through the
admin UI, is a documented prerequisite for electronic ordering, and is not a
catalogue modification.

## Phase 1 — catalogue sync in the bridge

New component in `services/Bridge`, roughly `CatalogueSync.cs`.

1. **OpenELIS REST client** holding a service-account session, re-authenticating
   on 401/302-to-LoginPage. Credentials from `.env`
   (`OE_SERVICE_USER` / `OE_SERVICE_PASSWORD`), never hardcoded.
2. **Sync is manual, not scheduled.** A clinic changes its test menu when it
   installs an analyser — a handful of times a year. A polling loop would run
   thousands of times to catch that, and would slide changes in unnoticed.
   Triggers:
   * `POST /catalogue/sync` (admin only)
   * `make sync-catalogue`, for deployment
   * a "Refresh test catalogue from OpenELIS" button on the HIS admin screen
   * once on bridge startup **only if `bridge.test_catalogue` is empty**, so a
     fresh deployment is not dead on arrival

   A sync run:
   * authenticates, pages `/rest/test-catalog/tests`
   * for each `active` row, fetches `/basic-info` and `/terminology`
   * keeps only tests where `active && orderable`, exactly one LOINC mapping,
     and exactly one sample type
   * swaps the whole set into `bridge.test_catalogue` in ONE transaction, with
     `synced_at` - there must be no window in which the menu is empty
   * discards the session; no long-lived credential to refresh
   * returns a diff summary: `+2 added, -1 removed, 3 changed`, with names

3. **Endpoint** `GET /catalogue` returning the cached rows:
   `{ testId, loinc, name, specimenName, specimenId, unit, syncedAt }`.

4. **Two guards, which matter more precisely because sync is manual.**
   * **Refuse a suspicious result.** An expired session returns an empty list,
     not an error; applying it would wipe the doctor's menu. Reject a sync
     yielding zero tests, or dropping more than ~30% of the catalogue, unless
     explicitly forced.
   * **Make the diff visible.** The operator pressing the button should see
     what changed. A scheduled sync hides "Haemoglobin disappeared" in a log;
     a manual one puts it on screen in front of the person who caused it.

5. **Never serve an empty catalogue.** If a sync fails, keep the last good copy
   and expose staleness — an empty dropdown must not be the failure mode of an
   OpenELIS restart.

6. **Surface `syncedAt` on the HIS ordering screen.** Manual sync means the
   catalogue will drift eventually. The remedy is making drift visible, not
   pretending it cannot happen.

### Operational procedure (for the clinic runbook)

When the laboratory commissions a new analyser:

1. Lab confirms which tests the analyser performs.
2. **IT enables those tests in OpenELIS** — Administration -> Test Management.
   Each test intended for HIS ordering must end up with exactly one LOINC code
   and exactly one sample type, or discovery will filter it out on purpose.
3. IT presses **Refresh test catalogue** in the HIS.
4. IT reads the diff and confirms it matches what the lab asked for.
5. A doctor sees the new test in the dropdown.

The order matters: syncing before step 2 changes nothing, which looks like a
broken button. Say so in the runbook.

**Verify during implementation:** we know OpenELIS caches sample-type bindings
in memory — a direct database edit stayed invisible until the webapp restarted.
Changes made through the admin UI ought to invalidate that cache properly, but
this has not been tested. Confirm that a test enabled through the admin UI
appears in `/rest/test-catalog` without a restart. If it does not, step 2 of the
procedure needs a restart in it, and that is a much heavier operation to ask of
a clinic.

### Open question to settle first

~400 sub-resource calls per full refresh (2 × 201 active tests). Before building
the N+1 loop, check whether `/rest/test-catalog/group/summary` or
`/rest/test-catalog/group/ranges` returns LOINC and sample types in bulk. If so,
use it. If not, N+1 on a 15-minute timer is acceptable, but add
`If-Modified-Since` or an ETag if OpenELIS honours either.

## Phase 2 — the HIS consumes it

1. `GET /test-catalogue` in `His.Api` proxies the bridge instead of reading
   `his.test_catalogue`.
2. `his.test_catalogue` becomes a **mirror**, refreshed from the bridge. Keep the
   table: order rows reference the test code, and the HIS must stay readable when
   the bridge is down.
3. `CreateOrderAsync` validates the test code against the mirror and takes the
   LOINC and specimen from it rather than from a hardcoded row.
4. The frontend dropdown renders whatever the endpoint returns. No code change
   expected beyond removing any hardcoded fallback.
5. **Keep `DRIFT`** (LOINC `99999-9`, deliberately unmapped) as a locally-injected
   row. The negative suite relies on OpenELIS rejecting an unresolvable order, and
   discovery would otherwise make that case unreachable.

## Phase 3 — tests and documentation

* Sync unit tests: ambiguous test excluded; non-orderable excluded; inactive
  excluded; multi-LOINC excluded.
* Integration test: order a test taken from `/catalogue` and assert
  `LabOrderSearchProvider` returns `sampleTypes` populated and `crosstests` empty.
  That is the assertion that would have caught this session's bug on day one.
* Failure test: OpenELIS unreachable → `/catalogue` still serves the last good
  copy, flagged stale.
* Update `docs/data-flow.md` with the discovery path.
* Update the runbook: `external orders = true` is a required prerequisite.

## Carried over — unrelated open items

Three genuine defects found while diagnosing this, none blocking:

1. **Requester never populates.** `LabOrderSearchProvider` returns `requester: ""`
   although `Task.requester` and `ServiceRequest.requester` both point at a
   Practitioner that OpenELIS imported into `clinlims.provider` with a matching
   `fhir_uuid` and `active = true`. Setting `provider.external_id` made no
   difference (tested and reverted). Next step: read the provider class out of the
   deployed WAR, the way the frontend source map settled the prefill question.
2. **`crosstest` / `crosstests` key mismatch.** `addOrder/Index.jsx` reads
   `order.crosstest`; the provider emits `order.crosstests`. The chooser is fed an
   empty array and never renders, so an ambiguous order gives the accessioner no
   prompt at all. We route around it rather than through it.
3. **`?ID=` lost by the Enter Order button.** `EOrder.jsx saveEntry` builds
   `SamplePatientEntry?ID=<externalOrderId>&labNumber=...` via
   `window.open(..., "_blank")`. Opening that URL directly works every time;
   through the button the wizard arrived empty at least once. Not reproduced since.
   Needs the address bar captured at the moment it fails.

Worth reporting upstream together against 3.2.1.11.

## Left over from this session

* Re-run the four suites — the catalogue change moved `his.test_catalogue`
  specimens (GLUC, CREA, CHOL) and `test-result-return.sh` may hardcode the old
  values.
* Commit `scripts/reset-orders.sh`, `scripts/watch-for-real-result.sh`,
  `db/his/003_catalogue_alignment.sql`, the Makefile change and the rewritten
  provisioning script.

Note the ordering: if Phase 0 goes ahead, the provisioning script and
`003_catalogue_alignment.sql` are reverted rather than kept. Commit them anyway,
so the history records what was tried and why it was undone.
