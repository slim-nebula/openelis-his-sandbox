# What actually arrives with an electronic order

**Question this answers:** when the HIS sends a lab order electronically, how much
of the OpenELIS order is filled in automatically, and what must a laboratory
technician still type by hand?

**Verified against:** OpenELIS Global 2 **3.2.2.0** source (tag `3.2.2.0`,
commit `aa00894`). Statements below cite the file and line they come from.
Anything not yet observed on a running system is marked *unverified*.

---

## 1. How the prefill works

Two paths exist in 3.2.2.0, and they are not equally capable. This is the single
most important thing to understand before reading the table.

### Path A — remote Task poll (what this sandbox uses today)

OpenELIS polls our FHIR endpoint, imports `Task` + `ServiceRequest` + `Patient` +
`Specimen`, and lists the order under **Order → Incoming Orders**. When the
technician opens it, the Add Order screen is prefilled from an XML document built
by `LabOrderSearchProvider.createOrderXML()`:

```java
xml.append("<order>");
addRequester(xml);        addRequestingOrg(xml);
addLocation(xml);         addPatientGuid(xml, patientGuid);
addSampleTypes(xml);      addCrossPanels(xml);
addCrosstests(xml);       addAlerts(xml, patientGuid);
xml.append("</order>");
```

**That list is exhaustive.** Whatever is not in it cannot be prefilled, because
the frontend has nothing else to read — `Index.jsx` consumes exactly
`order.patient`, `order.requester`, `order.requestingOrg`, `order.location`,
`order.sampleTypes`, `order.crosstest`, `order.crosspanel` and `order.user_alert`.

Everything else on the Add Order form — diagnosis, payment, billing reference,
referring patient number, next visit date, program, test location — is stored as
**ObservationHistory** rows keyed by `ObservationType`, and
`SampleOrderService` reads them *back off a saved sample*
(`SampleOrderService.java:145-170`). They are written when the technician saves
the form. **No inbound FHIR path writes them.** Every use of
`ObservationHistory` in `dataexchange/` is outbound — building FHIR *from*
OpenELIS, never the reverse.

### Path B — direct ServiceRequest create (not currently used)

OpenELIS's own FHIR endpoint exposes a create operation:

```java
@Create
public MethodOutcome createServiceRequest(@ResourceParam ServiceRequest serviceRequest,
                                          HttpServletRequest request)
```
`fhir/providers/ServiceRequestProvider.java:166`

It builds the order through a **different and better** mapper,
`FhirTransformServiceImpl.buildSampleOrderItemFromServiceRequest()`
(`:2791`), which reads fields Path A ignores entirely:

| Field | Source | Line |
|---|---|---|
| request date | `serviceRequest.getAuthoredOn()` | 2846 |
| priority (STAT / TIMED / ROUTINE) | `serviceRequest.getPriority()` | 2858 |
| requester → provider, first/last name | `serviceRequest.getRequester()` | 2878 |
| requester sample id | `serviceRequest.getSpecimen()` | 2841 |

and it generates the lab number server-side, with no Add Order screen involved.

**This is the more capable integration surface, and it is stock upstream.**

It remains an option rather than a plan, for one reason that is not technical: it
creates the sample immediately, so OpenELIS records receipt of a specimen nobody
has physically confirmed arrived. Specimen receipt is a real event in the
laboratory, and turning it into a side effect of an API call is a laboratory
process decision, not an integration one.

*Unverified — read from source, never exercised.*

---

## 2. The field map

**This was rewritten on 2026-08-24 after a deliberate simplification.** Three
things that used to travel no longer do, and each removal closed a defect rather
than working around one. What is listed here is what the integration actually
carries now.

### A. What an order carries

| OpenELIS field | HIS source | Sent as | Arrives |
|---|---|---|---|
| External order number | `lab_orders.order_number` | `ServiceRequest.identifier[0]` | yes |
| Referring lab number | `lab_orders.order_number` | `ServiceRequest.requisition` | yes |
| Patient name, sex, DOB | `patients.*` | `Patient` | yes |
| National ID | `patients.national_id` | `Patient.identifier` (`…/pat_nationalId`) | yes |
| HIS patient id | `patients.patient_id` | `Patient.identifier` (`…/pat_guid`) | yes |
| Phone | `patients.phone` | `Patient.telecom` | yes |
| Test | `test_catalogue.loinc_code` | `ServiceRequest.code` (LOINC) | yes |
| **Specimen** | `test_catalogue.specimen_type` | `Specimen.type` | yes — and load-bearing, see §3 |
| Priority | `lab_orders.priority` | `ServiceRequest.priority` | yes |

Sex and date of birth are not descriptive. `ResultLimitServiceImpl.selectForPatient()`
picks the reference range four ways from them — age and sex, sex only, age only,
or a default — and a missing value does not fail, it silently selects a LESS
specific range. `make e2e` asserts both survive the trip.

### B. Deliberately not sent

| Field | Why not |
|---|---|
| **Patient file number (MRN)** | The HIS owns the patient record and resolves it from `patient_id`. Sending it would be a second copy of something the caller already holds. OpenELIS also discarded it — its inbound mapper matches identifiers by `system`, and the file number's only carrier was a type coding with no system. |
| **Ordering clinician** | The laboratory does not act on it: the analysis is driven by the test and the specimen, and a critical value is phoned back to the HIS, which knows the doctor. Attribution stays complete in the HIS — `lab_orders.ordering_provider_id` from the verified token, plus `his.audit_events`. |
| **Visit / encounter** | Never has to survive a round trip. A returning result is matched to its ORDER first, and the order remembers the visit. OpenELIS would drop it anyway — encounter handling is commented out at `FhirApiWorkFlowServiceImpl.java:577`. |
| Requesting organisation, location | Not needed once the requester is not shown. Was previously listed here as a gap to close; it is not a gap, it is out of scope. |

Not sending the clinician retired an upstream defect outright — see §4.

### C. What a returning result carries

| Field | Source |
|---|---|
| `patientId` | the local order row, never the LIS message |
| `visitNumber` | joined from `lab_orders` |
| `orderNumber` | joined from `lab_orders` — the precise key, since one visit holds many orders |
| `resultValue`, `resultUnit`, `referenceRange`, `interpretation`, `resultStatus` | the LIS |
| `openelisResultRef` | mandatory back-reference to the record OpenELIS owns |

`GET /visits/{visitNumber}/results` answers the question a clinician opening an
encounter actually asks.

### D. Still typed by hand in the laboratory

Diagnosis, payment option, billing reference, next visit date, program, test
location. These are `ObservationHistory` rows, written when the accessioner
saves. **No inbound FHIR path writes them** — every use of `ObservationHistory`
in `dataexchange/` is outbound. `ServiceRequest.reasonCode`, the natural slot for
a diagnosis, is never read anywhere in OpenELIS.

Accessioning itself is deliberately manual: a physical specimen has to arrive and
be checked.

## 3. Why the specimen is load-bearing

A LOINC code says WHAT is measured, not what it is measured IN. OpenELIS's
catalogue has `10351-5` on three tests (HIV viral load on DBS, plasma, serum) and
`94547-7` on four.

OpenELIS 3.2.2.0 resolves this (`OGC-1145`), but in **two separate places**, and
conflating them hid a real defect in this integration for some time.

| where | method | what it decides |
|---|---|---|
| import | `TaskInterpreterImpl.createTestFromFHIR` | only whether to **hold** the order `AwaitingSpecimen`. A carried `Specimen` skips the hold — then it binds `tests.get(0)` regardless. |
| accession | `LabOrderSearchProvider.addToTestOrPanel` | which test is **actually bound**. |

An order importing as status 21 `Entered` rather than 29 `AwaitingSpecimen`
therefore proves only that the hold was skipped. It says nothing about whether
the right test was chosen. That observation was previously written up here as
proof of correct resolution; it was not.

**What actually binds the test:**

```java
// LabOrderSearchProvider.addToTestOrPanel
String id = typeOfSampleService.getTypeOfSampleIdForLocalAbbreviation(code);  // exact
test = testService.getActiveTestByLoincCodeAndSampleType(loinc, id).orElse(null);
if (test == null) test = alltests.get(0);      // <- silent first-match fallback
```

`code` comes from the one `Specimen.type.coding` whose system is exactly
`<oeFhirSystem>/sampleType`. Nothing else is consulted — not `text`, not a SNOMED
coding. And the key is `type_of_sample.local_abbrev`, **not** the display name:

| description | local_abbrev |
|---|---|
| Serum, Plasma, DBS, Sputum, Fluid | identical |
| Whole Blood | `Whole Bld` |
| Respiratory Swab | `Resp Swab` |

So the bridge sends **both** codings: `<oeFhirSystem>/sampleType` carrying the
abbreviation (what OpenELIS binds by) and SNOMED (what everyone else reads).
`bridge.test_catalogue.specimen_abbrev` caches the abbreviation, fetched from
`GET /rest/sample-types` — the only endpoint that exposes it.

So the catalogue offers **one row per (test, specimen)** and the doctor picks the
variant — the only point in the workflow where the answer is known for certain.
That took the menu from 4 tests to 17.

**Failure here is silent, which is why it is asserted rather than trusted.** A
missing or stale abbreviation does not error: OpenELIS logs a warning and binds
the first active test on the LOINC. For the 13 offered tests whose LOINC has more
than one candidate, that is very often the wrong bench — a plasma HIV viral load
would bind the serum test. The catalogue sync now refuses to offer a specimen
with no abbreviation, the bridge refuses to map an order without one, and
`make catalogue-test` asserts every cached abbreviation still matches OpenELIS.

Still refused: two tests sharing a LOINC **and** a specimen. `94547-7` is mapped
to both COVID IgG and IgM on the same specimens, so nothing in an order could
separate them and both are dropped rather than guessed. That is a mapping error
in the laboratory's catalogue, and the sync log names it.

## 4. Upstream defects, and where they stand

**Defect 1 — concurrent Task poll.** `@Scheduled(fixedRateString=…)` plus `@Async`
on a `SimpleAsyncTaskExecutor`: nothing serialises the job, so any execution that
outruns the interval is joined by the next. Causes duplicate patients, an
unbounded re-import loop, and `Task.status = rejected` reported for an internal
indexing failure — indistinguishable from a clinical refusal. **Unchanged in
3.2.2.0.** Contained by our delivery lease, which prevents two overlapping
deliveries; the over-firing poll and the `rejected` conflation stay upstream's.

**Defect 2 — the ambiguous-test chooser never renders.** `Index.jsx:221-222` reads
`order.crosstest` / `order.crosspanel`; the server emits `<crosstests>` /
`<crosspanels>`. The chooser is fed an empty array and its `length > 0` guard
never opens. Its unit test passes because the fixture was written to the wrong
shape too, so the broken path has green coverage. **Unchanged in 3.2.2.0.**
We never reach it, because the specimen resolves the order first (§3).

**Defect 3 — the requester renders empty.** `Task.owner` is the routing address —
it is how OpenELIS finds orders addressed to it
(`Task.OWNER.hasAnyOfIds(remoteStoreIdentifier)`) — and `LabOrderSearchProvider`
reads the requester from that same field FIRST, so the fallback to
`ServiceRequest.requester` is unreachable and the name fields are never set.
The same field cannot be both the address and the sender. **Unchanged in 3.2.2.0,
and no longer applies to us:** we do not send an ordering clinician at all.

**Not filed:** `?ID=` lost by the Enter Order button. One unreproduced occurrence
against code with no async gap; filing it invites a "cannot reproduce" close that
makes the other three easier to dismiss.
