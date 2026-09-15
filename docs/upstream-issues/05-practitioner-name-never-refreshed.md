# An imported Practitioner's name is frozen at first import and never refreshed

## Summary

The first time OpenELIS imports a remote `Practitioner`, it copies it into the
local FHIR store. On every later order referencing that same clinician, it finds
the local copy by identifier and reuses it **as it is** — the incoming resource
is discarded and no new version is written.

A clinician's name in OpenELIS is therefore fixed at the moment the laboratory
first saw them. A name corrected in the sending system — a misspelling, a
transliteration fixed, a married name — never reaches OpenELIS, and so never
reaches the laboratory's report or the accessioning screen.

## Where

`FhirApiWorkFlowServiceImpl.saveRemoteTaskAsLocalTask()`, tag `3.2.2.0`
(`aa00894`):

```java
// ServiceRequest Requester
objects.requestors = new ArrayList<>();
for (Practitioner remotePractitioner : remoteRequesters) {
    Practitioner localPractitioner;
    Optional<Practitioner> existingLocalRequester =
            getProviderWithSameIdentifier(remotePractitioner, remoteStorePath);
    if (existingLocalRequester.isEmpty()) {
        localPractitioner = remotePractitioner
                .addIdentifier(createIdentifierToRemoteResource(remotePractitioner, remoteStorePath));
        fhirOperations.updateResources.put(localPractitioner.getIdElement().getIdPart(), localPractitioner);
    } else {
        localPractitioner = existingLocalRequester.get();   // <- remote resource discarded
    }
    objects.requestors.add(localPractitioner);
}
```
`:689-703`

The `else` branch takes the stored copy and never compares it with, or updates it
from, `remotePractitioner`. The same shape appears for the Task's own
practitioner at `:671-686`.

## Reproduction

1. Publish an order whose `ServiceRequest.requester` references
   `Practitioner/<uuid>` named "Fatou Diallo". Let OpenELIS import it.
2. Publish a second order referencing **the same** `Practitioner/<uuid>`, now
   named "Fatou Diallo-Sow". Let OpenELIS import it.
3. Read the resource back:

```sql
SELECT count(*) AS versions
  FROM clinlims.hfj_res_ver v
  JOIN clinlims.hfj_resource r ON r.res_id = v.res_id
 WHERE r.fhir_id = '<uuid>';
--  versions
--  --------
--         1
```

One version. The name it holds is whichever of the two arrived first, and the
second was silently dropped.

## Why keying on the name instead is not the answer

The obvious workaround from the sending side — derive the Practitioner id from
the clinician's name so a changed name becomes a new resource — is worse. It
makes "Dr Konate", "Dr Konaté" and "dr konate" three different clinicians in the
laboratory's own provider records, which is a data-quality defect rather than a
display one. A stable identity with a stale name is the better of the two, which
is why this needs fixing in OpenELIS rather than routed around.

## Impact

Low severity, no data loss, but it is invisible: the sending system's record and
OpenELIS's record disagree indefinitely, and neither side logs that an update was
received and dropped. For a laboratory report that names the ordering clinician,
the name printed may be one the sending system corrected months earlier.

## Suggested direction

In the `else` branch, update the stored resource from the remote one — at minimum
`name` and `telecom` — rather than discarding it, keeping the local id and the
`externalId` identifier. If overwriting is undesirable by policy, logging that an
update was received and not applied would at least make the divergence
detectable.

## Environment

- OpenELIS Global 2 v3.2.2.0, official image `itechuw/openelis-global-2:3.2.2.0`
- HAPI FHIR JPA store co-resident, sharing the OpenELIS database
- Line numbers are from tag `3.2.2.0` (`aa00894`)
