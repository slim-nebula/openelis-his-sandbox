# Requester renders empty on Incoming Orders for imported electronic orders

**Version:** 3.2.1.11 (`itechuw/openelis-global-2:develop`)
**Area:** `org.openelisglobal.common.provider.query.LabOrderSearchProvider`

## Summary

For orders imported from a remote FHIR source, the Incoming Orders view renders
an empty `<requester>` element. The ordering clinician's name never appears, so
a technician accessioning the order cannot see who requested the test.

## Reproduction

1. Configure a remote FHIR source (`org.openelisglobal.remote.*`).
2. Publish `Task` + `ServiceRequest` + `Patient` + `Practitioner`, where
   `ServiceRequest.requester` references the ordering clinician's Practitioner
   and `Task.owner` references the receiving laboratory's Practitioner.
3. Let OpenELIS import the order, then open Order → Incoming Orders.

**Expected:** the requester's name is shown.
**Actual:** `<requester>` is emitted with all fields blank.

## What has been ruled out, with evidence

This is the useful part of the report: the three obvious explanations are all
false in our deployment, so please do not start with them.

**1. It is not `provider.external_id`.** Integration guidance in the wider
ecosystem (Bahmni's OpenMRS↔OpenELIS notes) says to populate
`clinlims.provider.external_id` so the requester name appears. That does not
apply to this version, and setting it changed nothing. `ProviderService` in the
deployed WAR exposes only:

```
getProviderByFhirId(UUID)      insertOrUpdateProviderByFhirUuid
getProviderIdByFhirId(UUID)    getProviderByPerson
```

There is no lookup by `external_id` at all.

**2. It is not a missing or inactive provider row.** `clinlims.provider` holds a
row for the clinician, `active = 't'`, whose `fhir_uuid` exactly matches the
Practitioner id that `ServiceRequest.requester` references.

**3. It is not a reassigned id in the local FHIR store.** `LabOrderSearchProvider`
resolves the requester by reading a Practitioner out of OpenELIS's own FHIR
store — `task.getOwner()` first, falling back to
`serviceRequest.getRequester()` — so the natural explanation is that import
reassigns ids and those reads miss. It does not. Both Practitioners are present
under exactly the ids we publish, neither deleted:

```sql
SELECT fhir_id, res_type, res_deleted_at IS NOT NULL AS deleted
  FROM clinlims.hfj_resource WHERE res_type = 'Practitioner';

 0e11c5a0-0000-4000-a000-000000000001 | Practitioner | f   <- Task.owner
 3537c59e-aaf8-51b4-92f0-3d5c15b137e9 | Practitioner | f   <- ServiceRequest.requester
```

`Task.owner` — which the code reads *first* — resolves to a Practitioner that is
present and undeleted. So whatever empties `<requester>` happens **after a read
that should succeed**.

## Not the cause

- `PractitionerRole` is not consulted anywhere in this path.
- `sample_requester` is populated at accession and is not read by
  `LabOrderSearchProvider`, so this is not "blank until accessioned".
- The multiple fallback reads in `processRequest()` show the intent is to
  display the requester on this view, not to withhold it.

## Impact

The laboratory cannot see who ordered a test from the screen where it accessions
it. For an integrating system, it also means the ordering clinician's identity
is transmitted correctly and then lost at the point of use.

## Environment

- OpenELIS Global 2 v3.2.1.11, `itechuw/openelis-global-2:develop`
- HAPI FHIR JPA store co-resident, sharing the OpenELIS database
- Practitioner resources carry both a display-name identifier and an external
  system's user id under its own identifier system
