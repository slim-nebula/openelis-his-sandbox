# Requester renders empty on Incoming Orders: `Task.owner` shadows `ServiceRequest.requester`

**Version:** 3.2.2.0 (tag `3.2.2.0`, commit `aa00894`)
**Area:** `org.openelisglobal.common.provider.query.LabOrderSearchProvider`

## Summary

For orders imported from a remote FHIR source, the Incoming Orders view renders
`<requester>` with no name. The ordering clinician published in
`ServiceRequest.requester` is never displayed, because the same field OpenELIS
uses to *route* the order — `Task.owner` — is also the first field the requester
lookup reads, and it always wins.

## Root cause

Two blocks are involved, and the interaction between them is the defect.

**1. `Task.owner` is read first, and the fallback is guarded on it being null**
(`LabOrderSearchProvider.java:234-263`):

```java
if (!GenericValidator.isBlankOrNull(task.getOwner().getReferenceElement().getIdPart())
        && task.getOwner().getReference().contains(ResourceType.Practitioner.toString())) {
    requesterPerson = localFhirClient.read()
            .resource(Practitioner.class)
            .withId(task.getOwner().getReferenceElement().getIdPart())
            .execute();
}

if (requesterPerson == null) {                    // <- only reached if owner missed
    ... serviceRequest.getRequester() ...
}
```

The difficulty is that `Task.owner` is not a free field for an integrator to
leave blank. It is the **routing address** OpenELIS itself filters remote Tasks
on (`Task.OWNER.hasAnyOfIds(remoteStoreIdentifier)`). An order that omits it is
never imported at all. So for every order that *does* arrive, `Task.owner` is
populated and resolvable — meaning `requesterPerson` is always the **receiving
laboratory's** Practitioner, and the `ServiceRequest.requester` branch is
effectively dead code.

**2. The else branch never sets a name** (`LabOrderSearchProvider.java:388-418`):

```java
if (requesterPerson != null) {
    ...
    requesterValuesMap.put(PROVIDER_LAST_NAME,  requesterPerson.getNameFirstRep().getFamily());
    requesterValuesMap.put(PROVIDER_FIRST_NAME, requesterPerson.getNameFirstRep().getGivenAsSingleString());
} else {
    Provider provider = providerService
            .getProviderByFhirId(UUID.fromString(task.getOwner().getReferenceElement().getIdPart()));
    if (provider != null) {
        requesterValuesMap.put(PROVIDER_ID, provider.getId());
        requesterValuesMap.put(PROVIDER_PERSON_ID, provider.getPerson().getId());
    }
    // no PROVIDER_FIRST_NAME, no PROVIDER_LAST_NAME
}
```

So there are two ways to end up with a nameless requester: the else branch never
populates the name keys at all, and the if branch populates them from whichever
Practitioner `Task.owner` pointed at — which is the laboratory, not the clinician.

## What this is *not*

Three plausible explanations are all false; please don't start with them.

**Not `provider.external_id`.** Ecosystem guidance (Bahmni's OpenMRS↔OpenELIS
notes) suggests populating `clinlims.provider.external_id` so the requester name
appears. `ProviderService` has no lookup by `external_id` — resolution is by
`fhir_uuid` only (`getProviderByFhirId`). Setting it changes nothing.

**Not a missing or inactive provider row.** `clinlims.provider` holds a row for
the clinician, `active = 't'`, whose `fhir_uuid` matches the Practitioner that
`ServiceRequest.requester` references.

**Not reassigned ids in the local FHIR store.** Both Practitioners are present
under exactly the ids published, neither deleted:

```sql
SELECT fhir_id, res_type, res_deleted_at IS NOT NULL AS deleted
  FROM clinlims.hfj_resource WHERE res_type = 'Practitioner';

 0e11c5a0-0000-4000-a000-000000000001 | Practitioner | f   <- Task.owner
 3537c59e-aaf8-51b4-92f0-3d5c15b137e9 | Practitioner | f   <- ServiceRequest.requester
```

`Task.owner` resolves to a present, undeleted Practitioner — which is precisely
why the clinician is never reached.

## Impact

The laboratory cannot see who ordered a test from the screen where it accessions
that test. For an integrating system, the ordering clinician's identity is
transmitted correctly and then discarded at the point of use, with no diagnostic.

## Suggested direction

Prefer `ServiceRequest.requester` over `Task.owner` when resolving the requester,
or read them into separate fields — `Task.owner` answers "which lab is this for",
which is a different question from "who ordered it". Whichever is chosen, the
else branch should populate the name keys too.

## Environment

- OpenELIS Global 2 v3.2.2.0, official image `itechuw/openelis-global-2:3.2.2.0`
- HAPI FHIR JPA store co-resident, sharing the OpenELIS database
- Line numbers are from tag `3.2.2.0` (`aa00894`)
