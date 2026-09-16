# An imported Patient's demographics are frozen at first import and never refreshed

## Summary

The first time OpenELIS imports a remote `Patient`, it copies it into the local
FHIR store. On every later order for that same patient, it finds the local copy
by identifier and reuses it **as it is** — the incoming resource is discarded and
no new version is written.

A patient's name in OpenELIS is therefore fixed at the moment the laboratory
first saw them. A name corrected in the sending system — a misspelling, a
transliteration fixed, a married name, a transposition caught at the registration
desk — never reaches OpenELIS, and so never reaches the specimen label, the
worksheet or the report.

This is the same defect as
[05](05-practitioner-name-never-refreshed.md) in a different resource, and it
matters considerably more. A clinician's name being stale is a reconciliation
nuisance. A **patient's** name being stale means the laboratory and the ordering
system disagree about whose specimen is on the bench, which is the
misidentification failure ISO 15189:2022 §7.2 and §7.3 treat as the most serious
error a laboratory can make.

## Where

`FhirApiWorkFlowServiceImpl.saveRemoteTaskAsLocalTask()`, tag `3.2.2.0`
(`aa00894`). Disassembled from the deployed
`WEB-INF/classes/.../FhirApiWorkFlowServiceImpl.class`:

```
725: invokevirtual  getPatientWithSameServiceIdentifier:(Patient;String;)Optional;
732: invokevirtual  java/util/Optional.isEmpty:()Z
735: ifeq           786                    // already present -> jump

     // absent: stamp the remote identifier on it and queue it for writing
738-753: Patient.addIdentifier(createIdentifierToRemoteResource(...))
756-782: fhirOperations.updateResources.put(patient.getIdElement().getIdPart(), patient)
783: goto           799

     // present: take the stored copy, discard the incoming one
786: aload          6
788: aload          16
790: invokevirtual  java/util/Optional.get:()Ljava/lang/Object;
793: checkcast      org/hl7/fhir/r4/model/Patient
796: putfield       OriginalReferralObjects.patient
```

The branch at `786` assigns the stored `Patient` and never compares it with, or
updates it from, the remote one. It is byte-for-byte the same shape as the
`Practitioner` handling at `:689-703` reported in defect 05.

## Reproduction

Automated as `scripts/test-patient-refresh.sh` in this repository
(`make patient-refresh`). By hand:

1. Register a patient as `Freezetest`, place an order, let OpenELIS import it.
2. Correct the surname to `Corrected` in the sending system.
3. Place a second order for **the same patient identifier**. Let OpenELIS import
   it. Confirm the sender really published the new name.
4. Read back what OpenELIS holds:

```sql
SELECT pe.last_name
  FROM clinlims.patient p
  JOIN clinlims.person pe ON pe.id = p.person_id
  JOIN clinlims.patient_identity pi ON pi.patient_id = p.id
 WHERE pi.identity_data = '<sending system patient id>';
--  last_name
--  -----------
--  Freezetest        <- the correction never arrived

SELECT count(*) AS versions
  FROM clinlims.hfj_res_ver v
  JOIN clinlims.hfj_resource r ON r.res_id = v.res_id
 WHERE r.res_type = 'Patient' AND r.fhir_id = '<uuid>';
--  versions
--  --------
--         1         <- no second version was ever written
```

Observed on 3.2.2.0 with the second order importing successfully — the order
arrives, the demographics do not.

## Impact

- **Specimen labels and reports carry a name the sending system has corrected.**
  The laboratory prints what it holds.
- **Reconciliation against the HIS fails on exactly the records where it matters
  most** — the ones somebody has already had to correct once.
- **The divergence is permanent and silent.** No error, no warning, no second
  version in the FHIR store. Nothing on either side reports that the two systems
  now hold different names for one patient.
- It cannot be worked around by re-sending. Re-sending is precisely what does
  not work.

## Suggested fix

In the `else` branch, update the stored resource from the incoming one rather
than discarding it — at minimum `name`, `gender`, `birthDate` and `telecom` —
and let the FHIR store write a new version. The identifier match has already
established that these are the same person, which is the hard part; the
remaining question is only which copy is current, and the answer is always the
one that just arrived from the system that owns the record.

If overwriting unconditionally is thought too strong, comparing the resources and
writing only on a difference would still be correct and would keep the version
history meaningful.

The same change applies to `Practitioner` at `:689-703` (defect 05).

## Workaround for integrators

There is none inside the integration. A demographic correction has to reach the
laboratory out of band — the laboratory edits the patient in OpenELIS itself —
and any HIS built on this boundary should say so plainly to whoever makes the
correction, rather than letting them believe it propagated.
