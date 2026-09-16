# Unresolvable sample type binds the wrong test silently (`alltests.get(0)`), and the key it needs is not exposed by the catalogue API

**Version:** 3.2.2.0 (tag `3.2.2.0`, commit `aa00894`)
**Area:** `org.openelisglobal.common.provider.query.LabOrderSearchProvider`,
`org.openelisglobal.typeofsample.service.TypeOfSampleServiceImpl`

## Summary

When an imported electronic order carries a specimen OpenELIS cannot resolve, it
does not reject the order or hold it for clarification. It **binds the first
active test matching the LOINC** and reports success. For a LOINC that spans
several specimen variants — which is the normal case, since a LOINC says what is
measured, not what it is measured in — that is a test nobody ordered, on a
specimen that does not match it.

The only signal is a `LogEvent.logWarn` in the server log. Nothing is returned to
the ordering system, and nothing distinguishes the outcome from a correct bind.

This is more severe than an order that fails to import: a failed import is
visible and gets fixed. This produces a plausible-looking order on the wrong
bench.

## The code

```java
// LabOrderSearchProvider.java:484-508 (addToTestOrPanel)
if (!GenericValidator.isBlankOrNull(sampleTypeAbbreviation)) {
    String typeOfSampleId =
        typeOfSampleService.getTypeOfSampleIdForLocalAbbreviation(sampleTypeAbbreviation);
    if (!GenericValidator.isBlankOrNull(typeOfSampleId)) {
        typeOfSample = typeOfSampleService.get(typeOfSampleId);
        if (typeOfSample != null) {
            test = testService.getActiveTestByLoincCodeAndSampleType(loinc, typeOfSample.getId())
                              .orElse(null);
        }
    }
}
if (test == null) {
    List<Test> alltests = testService.getActiveTestsByLoinc(loinc);
    if (alltests != null && alltests.size() > 0) {
        if (alltests.size() > 1) {
            LogEvent.logWarn(..., "LOINC " + loinc + " matches " + alltests.size()
                + " active tests and the order carried no usable specimen; the request stays"
                + " ambiguous until a specimen is chosen (OGC-1145)");
        }
        test = alltests.get(0);        // <- binds regardless
    }
}
```

The warning says the request "stays ambiguous until a specimen is chosen", but
the next line binds `alltests.get(0)` unconditionally. The order proceeds.

## Why the OGC-1145 chooser does not catch this

This is the part worth reading closely, because the obvious response — "multi-match
goes to the sample-type chooser now" — is true for only one of two catalogue
shapes, and not the common one.

Immediately after the first-match, `addToTestOrPanel:509-520` deliberately leaves
the sample type blank so `createMapsForTests` will route to the chooser:

```java
if (typeOfSample == null) {
    // OGC-1145: ... a multi-type test stays unbound (blank) so createMapsForTests
    // routes it to the user-facing sample-type chooser instead of first-match
    List<TypeOfSample> testTypes = typeOfSampleService.getTypeOfSampleForTest(test.getId());
    if (testTypes.size() == 1) {
        typeOfSample = testTypes.get(0);      // <- deterministic, so bind it
    }
}
```

That guard asks whether **one Test row spans several sample types**. It does not
ask whether **the LOINC spans several Test rows**. Those are different shapes:

| shape | example | behaviour |
|---|---|---|
| one test, several sample types | a test configured for Serum *and* Plasma | stays blank → chooser → safe (modulo the chooser defect below) |
| **one LOINC, several tests, each with one sample type** | `10351-5` → `HIVVIRALLOAD(Serum)`, `(Plasma)`, `(DBS)` | `testTypes.size() == 1` fires → **binds the first test's sample type** |

The second shape is how a stock catalogue expresses specimen variants, and it is
the one that silently mis-binds. Walking it through for `10351-5`:

1. specimen unresolvable → `typeOfSample == null`
2. `test = alltests.get(0)` → `HIVVIRALLOAD(Serum)`
3. `getTypeOfSampleForTest(313)` returns exactly one type → `typeOfSample = Serum`
4. `createMapsForTests` narrows candidates by `"Serum"` → exactly one pair
5. resolved, confidently, as **`HIVVIRALLOAD(Serum)`** — for a plasma order

No ambiguity is ever reported, because by step 4 there is none left to report:
step 3 manufactured certainty out of a first-match.

And where the chooser *is* reached (the first shape), it never renders — see the
`crosstest` / `crosstests` key mismatch filed separately. So neither shape has a
working safety net today.

## Why it is easy to hit

Two things have to be exactly right, and neither is discoverable from the
catalogue API.

**1. The coding system must match a string built at runtime.**
`LabOrderSearchProvider.java:444-455` accepts a sample type only from a
`Specimen.type.coding` entry whose system equals
`fhirConfig.getOeFhirSystem() + "/sampleType"`. A SNOMED coding — the obvious
thing for an integrator to send, and what FHIR implementers reach for first — is
ignored entirely, as is `Specimen.type.text`.

**2. The code must be `local_abbrev`, which is not the display name.**
`getTypeOfSampleIdForLocalAbbreviation` is an exact `HashMap` lookup keyed on
`TypeOfSample.getLocalAbbreviation()` (`TypeOfSampleServiceImpl.java:233,250`).
On a stock installation the two diverge for common specimens:

| `description` | `local_abbrev` |
|---|---|
| Serum, Plasma, DBS, Sputum, Fluid | identical |
| **Whole Blood** | **`Whole Bld`** |
| **Respiratory Swab** | **`Resp Swab`** |
| Histopathology specimen | `HPS` |
| Tissue antemortem | `TAM` |

So an integrator who sends the sample type's *name* — the value the catalogue API
gives them — silently mis-binds every order on those specimens.

**And `local_abbrev` is not available where integrators look.**
`GET /rest/test-catalog/tests/{id}/terminology` returns `sampleTypes[]` as
`SampleTypeOption { id, name, domain }` (`TestCatalogEditorRestController.java:1481-1487`),
where `name` is `description` falling back to `localAbbreviation` (`:1522`). The
abbreviation is exposed only by `GET /rest/sample-types` on
`SampleTypeManagementRestController`, an administrative endpoint. Nothing in the
catalogue surface indicates that the value it returns is not the value the order
path requires.

## Impact

Concretely, on a stock catalogue: LOINC `10351-5` carries three active tests
(HIV viral load on Serum, Plasma, DBS). An order for the **plasma** test whose
specimen does not resolve binds **`HIVVIRALLOAD(Serum)`** — first by id. The
laboratory sees a serum order it can accession normally. The specimen that
arrives is plasma.

There is no error, no `AwaitingSpecimen` hold, and no indication to the ordering
system that anything was substituted.

## Suggested direction

1. **Do not bind on a failed resolution.** If a sample type was supplied and did
   not resolve, that is a data problem, not an absent specimen — hold the order
   (`AwaitingSpecimen`) or reject it. Falling back to first-match is the one
   option that cannot be detected downstream. At minimum, distinguish "no sample
   type supplied" from "sample type supplied and unresolvable"; today both reach
   the same branch.
2. **Accept more than one key.** Resolve by sample type `id`, by `description`,
   and by SNOMED, not by `local_abbrev` alone. The id in particular is already
   handed to integrators by the catalogue API.
3. **Expose `localAbbreviation` on `SampleTypeOption`**, so the value the order
   path needs is available from the endpoint integrators actually use.

Any one of these would have prevented this. The first is the important one.

## Environment

- OpenELIS Global 2 v3.2.2.0, official image `itechuw/openelis-global-2:3.2.2.0`
- Remote FHIR order source; orders carry `Specimen` with `type.coding`
- Line numbers are from tag `3.2.2.0` (`aa00894`)
