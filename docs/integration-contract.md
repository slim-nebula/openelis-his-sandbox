# The integration contract

What crosses the boundary between a HIS and OpenELIS Global 2, exactly — what
you must send, what comes back, and the six things that fail **silently** if you
get them wrong.

Written for a developer designing the order their HIS will send. If you are
about to write the code, read [integration-guide.md](integration-guide.md)
alongside it; this document is the *what*, that one is the *how*.

> **Everything here was verified against the running system on 2026-09-15**, not
> carried forward from earlier notes. Claims about OpenELIS's own behaviour were
> checked against the **deployed bytecode** of 3.2.2.0 and its live
> configuration; claims about what the bridge sends were checked against the
> source and against real orders on the wire. Where something could not be
> verified, it says so.

---

## 1. The shape of it

A HIS order becomes up to **seven FHIR resources**. OpenELIS polls for the
`Task`, follows its references, and imports the order.

```
Task ──basedOn──▶ ServiceRequest ──requester──▶ Practitioner
 │                      │
 │                      ├──subject────▶ Patient
 │                      └──specimen───▶ Specimen
 ├──for────────▶ Patient
 ├──owner──────▶ Organization   ← the laboratory's routing address
 └──location───▶ Location       ← the referring site the order came from
```

Two are conditional. `Practitioner` is absent when the order carries no
identified clinician, and `Location` is absent when the site has no name — in
both cases absence is the honest statement rather than a gap to fill.

**Exactly one identifier has to survive the round trip: the order number.**
Everything else is re-derived locally. If your order numbers are unique,
immutable and match `[A-Za-z0-9-.]{1,64}`, the rest of the contract is
mechanical.

Results come back the other way as a `DiagnosticReport` referencing one or more
`Observation`s, pushed to the bridge rather than polled.

---

## 2. What you send

Real `Task`, published by the bridge on 2026-09-14 and stored as-is:

```json
{
  "id": "9454b40c-bc92-59a7-8216-3ae044886457",
  "resourceType": "Task",
  "status": "requested",
  "intent": "order",
  "priority": "routine",
  "identifier": [{ "system": "http://his-sandbox.local/lab-order",
                   "value": "LAB-20260914-48F8148B" }],
  "basedOn": [{ "reference": "ServiceRequest/LAB-20260914-48F8148B" }],
  "for": { "reference": "Patient/e0713979-8a2e-4545-89f0-a885ad6b0fa7" },
  "owner": { "reference": "Organization/26a13c4c-ce5f-48d9-9283-2a2d1d2c9ce4" },
  "authoredOn": "2026-09-14T21:49:49.273Z",
  "description": "HIV VIRAL LOAD (10351-5|DBS) — order LAB-20260914-48F8148B"
}
```

> The copy in the database now reads `"status": "accepted"` and carries a second
> identifier under `https://bridge.openelis.org:8443/fhir`. **OpenELIS wrote
> both back** after importing. Your Task leaves as `requested`; what you read
> later is the laboratory's answer.

### The fields, by resource

`…` below abbreviates `http://openelis-global.org`.

| Resource | Field | Source | Present |
|---|---|---|---|
| **Task** | `status` | literal `"requested"` | always — **the poll filters on it** |
| | `owner.reference` | `OE_REMOTE_SOURCE_IDENTIFIER` | always — **must be `Organization/…`** (§4.1) |
| | `identifier[0]` | order number | always |
| | `basedOn[0]` | `ServiceRequest/{orderNumber}` | always |
| | `for` | `Patient/{patientId}` | always |
| | `intent` / `priority` / `authoredOn` / `description` | — | always |
| **ServiceRequest** | `id` | **the order number itself** | always — **not a UUID** (§4.2) |
| | `identifier[0]` | order number, system `http://his-sandbox.local/lab-order` | always — becomes `electronic_order.external_id` |
| | `requisition` | order number, same system | always — shows as "referring lab number" |
| | `code.coding[0]` | LOINC, system `http://loinc.org` | always — **the only thing a test is matched on** |
| | `status` / `intent` | `"active"` / `"order"` | always |
| | `priority` | `stat` \| `asap` \| `routine` | always |
| | `subject` / `specimen[0]` / `authoredOn` | — | always |
| | `requester` | `Practitioner/{id}` | **only** when a clinical identity exists (§4.4) |
| **Patient** | `id` | your patient id, verbatim | always |
| | `identifier[0]` | `…/pat_guid` | always |
| | `identifier[1]` | `…/pat_nationalId` | only when a national id exists |
| | `name[0]` | family + given | always — **no digits** (§4.3) |
| | `gender` | `male` \| `female` \| `unknown` | always |
| | `birthDate` | — | always |
| | `telecom[0]` | phone, `use: "mobile"` | only when a phone exists |
| **Specimen** | `type.coding[…]` | `…/sampleType`, the **local abbreviation** | only when known (§4.5) |
| | `type.coding[…]` | `http://snomed.info/sct` | only when a SNOMED code exists |
| | `type.text` | specimen name | always |
| | `collection.collectedDateTime` | ward draw time | **inpatient only** — omitted otherwise |
| | `receivedTime` | — | **never sent** (§5) |
| **Practitioner** | `id` | UUID v5 of `practitioner\|{hcpId}` | **must be a UUID** (§4.4) |
| | `identifier[0]` | `…/hcp_id` | always |
| | `identifier[1]` | `…/provider_license` | when a licence exists |
| | `name[0]` | split from one display string | always |
| **Organization** | `id`, `identifier[0]` (`…/lab`), `name` | config | always |

### Resource ids

| Resource | id |
|---|---|
| Task | UUID v5, name `task\|{orderId}` |
| Specimen | UUID v5, name `specimen\|{orderId}` |
| Practitioner | UUID v5, name `practitioner\|{hcpId}` |
| ServiceRequest | **the order number**, verbatim |
| Patient | **your patient id**, verbatim |
| Organization | last segment of the configured owner reference |

UUID v5 is SHA-1 over the RFC 4122 DNS namespace
`6ba7b810-9dad-11d1-80b4-00c04fd430c8`. **The name strings are part of the
contract**, not just the algorithm: changing `task|` to `Task|` republishes
every order in the system under new ids, silently.

### Publication order

`Patient → Organization → Practitioner → Specimen → ServiceRequest → Task`, all
in **one transaction**.

The order matters because OpenELIS dereferences `ServiceRequest.requester` while
importing, so the Practitioner must be readable before anything points at it.
The transaction matters because a half-written order is one OpenELIS can poll
and then fail to dereference — the import fails on the laboratory's screen for a
reason invisible from your side.

---

### There is a second way in, and we do not use it

OpenELIS also exposes a **direct `ServiceRequest` create** on its own FHIR
endpoint (`ServiceRequestProvider.createServiceRequest`). It builds the order
through a different and in several ways better mapper
(`FhirTransformServiceImpl.buildSampleOrderItemFromServiceRequest`) which reads
fields the Task-poll path ignores outright — the authored date, the priority,
the requester's name, the specimen reference.

This sandbox uses the **remote Task poll** instead, because that is the path
OpenELIS itself drives: it polls you, on its own schedule, with no inbound
connection to your estate and no credential for it to hold. The create path
requires you to reach into OpenELIS, which inverts the network direction and the
trust boundary.

Worth knowing it exists. If your deployment can tolerate the HIS calling
OpenELIS directly, it fills in more of the order — but everything in this
document describes the poll path.

---

## 3. What comes back

A real `Observation` OpenELIS pushed, stored exactly as received:

```json
{
  "id": "9a51bee2-42c5-4473-aaa4-785f4466afc4",
  "resourceType": "Observation",
  "status": "final",
  "code": { "coding": [{ "system": "http://loinc.org",
                         "code": "2345-7", "display": "Glucose" }] },
  "valueQuantity": { "value": 5.4, "unit": "mmol/L",
                     "system": "http://unitsofmeasure.org", "code": "mmol/L" },
  "interpretation": [{ "coding": [{
      "system": "http://terminology.hl7.org/CodeSystem/v3-ObservationInterpretation",
      "code": "N", "display": "Normal" }] }],
  "referenceRange": [{ "low": { "value": 3.9 }, "high": { "value": 5.8 } }]
}
```

The bridge flattens that into a `lab.result.released` event. Fields in the order
emitted:

| Field | Meaning |
|---|---|
| `eventId`, `eventType`, `occurredAt`, `correlationId` | envelope |
| `orderNumber` | **your** order number, from tracking — not from the report |
| `openelisResultRef` | `DiagnosticReport/{id}` — the record that stays authoritative |
| `testCode` | your test code, from tracking |
| `testName` | the report's `code.text`, or a coding display |
| `resultValue`, `resultUnit`, `referenceRange`, `interpretation` | the **first** analyte — the compatibility view |
| `labCollectedAt` | when the laboratory says the specimen was drawn |
| `interpretationCode` | `N`/`H`/`HH`… — travels beside the label so you can tell *critical* from merely *abnormal* without parsing prose |
| `resultStatus` | `final` \| `amended` \| `corrected` \| `entered-in-error` |
| `releasedAt` | `issued`, else `effectiveDateTime`, else now |
| `observations[]` | **every** analyte: `position`, `code`, `name`, `value`, `unit`, `referenceRange`, `interpretation`, `interpretationCode` |

**Only four statuses reach you**: `final`, `amended`, `corrected`,
`entered-in-error`. Anything else (a preliminary report) publishes a *progress*
event and never a value — an unvalidated potassium looks exactly like a
validated one on a screen.

**A retraction (`entered-in-error`) nulls all five flat value fields and sends
`observations: []`.** The withdrawal is the whole message; shipping the old
number beside it invites someone to keep using it.

### Trust your own order row, not the message

The one-identifier rule has a consequence worth designing around: **match the
result to the order first, then read everything else from your own record.**

```
DiagnosticReport → basedOn → ServiceRequest → order number
                 → your lab_orders row → patient id, visit, test code
```

The patient id, the visit and the test code are all *sent* to the laboratory —
it needs demographics to do the work — but none of them should be read back out
of what it returns. This sandbox's HIS selects those columns by order number and
inserts what it read, not what arrived; even `testCode` and `testName` fall back
to the order's own values.

The order row is the authority. The message is a convenience.

---

### Progress

`lab.order.progress` carries `IN_LABORATORY` (the sample is physically there and
has an accession number) or `AWAITING_VALIDATION` (a result exists, unsigned).
Each fires **once per order per state**.

`accessionNumber` is only populated when `ServiceRequest.requisition.system` is
exactly `http://openelis-global.org/samp_labNo`. Checking for a *value* without
checking the *system* reports every order as "in the laboratory" the moment it
imports, quoting your own order number back as if it were an accession — that
mistake was made here, and 102 of 130 requests were echoes.

---

## 4. The six silent failures

Each of these produces **no error on either side**. That is what makes them
worth a section.

### 4.1 `Task.owner` must be an `Organization`

`LabOrderSearchProvider` looks for the requester in `Task.owner` first, and
takes it whenever the reference **contains the string `Practitioner`**. A
Practitioner-typed owner therefore matches, the fallback to
`ServiceRequest.requester` is never reached, and every order in the laboratory
is attributed to your routing identity instead of the real doctor.

*Verified:* `LabOrderSearchProvider` in the deployed 3.2.2.0 build carries
`Practitioner` as a bare string constant, alongside `addRequester`.

The owner UUID must also be a **real row** in OpenELIS's `organization` table
(`organization.fhir_uuid`) — it is emitted on `Task.restriction.recipient` for
outbound referrals, and must name something that exists.

### 4.2 `ServiceRequest.id` must be the order number

OpenELIS's Incoming Orders view reads `ServiceRequest/{external_id}` directly
from its FHIR store. Give the resource a UUID id and that read 404s: the lab
user sees *"error in data collection — FHIR resource not found"* with no test
name, on every order.

**Import still works**, because import follows `Task.basedOn` instead. That is
precisely why this stays invisible from the integration's side.

### 4.3 Names must not contain digits

*Verified against this deployment's live configuration:*

```
lastNameCharset    .'a-zàâçéèêëîïôûùüÿñæœ -     ← letters, accents, space, dot, apostrophe, hyphen
firstNameCharset   .'a-zàâçéèêëîïôûùüÿñæœ -
patientIdCharset   a-z0-9/àâçéèêëîïôûùüÿñæœ     ← digits ARE allowed here
```

Names reject digits; **identifiers accept them**. An order for a patient named
`Doe 2` — or a test fixture called `Probe233301` — stalls at `SENT_TO_LIS`
forever: no rejection, no dead letter, nothing in any log.

The bridge deliberately does **not** sanitise names. Stripping a character to
slip past validation would alter a person's identity in a clinical record to
avoid an error message. The laboratory refusing a malformed name is the correct
outcome; the fix belongs in the HIS that holds it.

### 4.4 The Practitioner id must be a UUID, keyed on the clinician

`LabOrderSearchProvider.addRequester` calls `UUID.fromString()` **unguarded**. A
raw id like `9042` throws inside the accessioning wizard — a 500 on the
laboratory's screen, not a missing field.

Key it on the **clinician** (`hcp.id`), never on:

- **the account** — nullable (a consultant may have no login) and non-unique, so
  it can collide;
- **the name** — "Dr Konate", "Dr Konaté" and "dr konate" would become three
  different clinicians in the laboratory's permanent provider records.

No clinical identity means **no `requester` at all**. Absent is the honest
statement; a Practitioner invented in transit reads as a verified attribution.

### 4.5 The specimen must carry the local abbreviation

*Verified:* `LabOrderSearchProvider` calls
`getTypeOfSampleIdForLocalAbbreviation` — an exact match on
`type_of_sample.local_abbrev`, **not** the display name. "Whole Blood" is stored
as `Whole Bld`, "Respiratory Swab" as `Resp Swab`.

Miss it and OpenELIS does not error: it binds the **first test matching the
LOINC**. For a code carried on several tests, a plasma order goes to the serum
bench with nothing logged anywhere.

This is why a LOINC alone is not enough. A LOINC says *what* is measured, not
*what it is measured in* — this laboratory carries `10351-5` on three different
tests. The catalogue is therefore keyed on **(LOINC, specimen)**, and an order
must carry both.

### 4.6 An order cannot be cancelled over FHIR

*Verified in the deployed bytecode:* the `OrderType` enum has three members —
`REQUEST`, `CANCEL`, `UNKNOWN`. `TaskInterpreterImpl`, which is the FHIR path,
references `REQUEST` 18 times and **`CANCEL` zero times**.

The cancellation machinery exists and is reachable from HL7. It is not reachable
from FHIR. There is no message to send and no error saying so — **a cancellation
sent as a revised order simply arrives as a second order.**

Design for this up front: either cancellation stays a telephone call to the
laboratory, or a cancelled order is one the laboratory will still run.

---

## 4b. What the laboratory still types by hand

The integration does not fill in the whole accessioning screen, and it is worth
knowing which blanks remain before someone reports them as a bug.

**Diagnosis, payment option, billing reference, next visit date, program and
test location** are all still typed by the accessioner. They are
`ObservationHistory` rows written when the sample is saved, and **no inbound
FHIR path writes them** — every use of `ObservationHistory` in OpenELIS's
`dataexchange/` package is outbound. `ServiceRequest.reasonCode`, the natural
slot for a diagnosis, is never read.

Accessioning itself is deliberately manual: a physical specimen has to arrive
and be checked against the order. That is a laboratory control, not a gap in the
integration.

---

## 5. What is deliberately not sent

| Not sent | Why |
|---|---|
| `Specimen.receivedTime` | It claimed the laboratory had received a specimen at the moment the doctor clicked "order" — before anyone drew blood. Receipt is an event the **laboratory** observes. |
| `Specimen.collection` when there is no draw time | An outpatient specimen is drawn in the laboratory. An empty element suggests we had something to say and lost it. |
| The patient's file number / MRN | It *does* work if sent as `…/pat_subjectNumber` — verified. It is omitted because the HIS can resolve it from the patient id, and shipping it puts a second copy of one fact somewhere new to drift. |
| The ordering **account** (`usr_id`) | Nullable, non-unique, and not how the clinical record identifies doctors. It stays in your audit trail. |
| The OpenELIS sample-type coding, when no abbreviation is known | A wrong code binds the wrong test confidently; an absent one leaves the decision with the laboratory. |

---

## 6. When the bridge refuses an order

Refusals happen **before** anything reaches the laboratory. Each writes a dead
letter and publishes `lab.order.failed` with `status: "FAILED"` and the reason
in `detail`.

| Condition | What it means |
|---|---|
| Order payload unparseable | Dead-lettered and committed past — unparseable now is unparseable forever, and blocking the partition helps nobody. |
| No LOINC code | OpenELIS cannot resolve a test at all. |
| On the menu, **no abbreviation** | Would bind the first test matching the code. Stale catalogue — re-sync. |
| LOINC offered, but **not on this specimen** | We know the code exists, possibly on several tests. Sending it without a resolvable sample type is exactly the input that mis-binds. |

**The deliberate exception.** If the LOINC is **absent from the catalogue
entirely**, the order is sent anyway, without a sample-type coding. The bridge
never discovered that test, so it has no opinion about it, and the laboratory is
the authority on what it accepts. OpenELIS will reject a code it does not carry,
and *that rejection travelling back is the drift signal the integration is built
on.* Refusing locally would substitute our judgement for the laboratory's and
delete the whole rejection path.

---

## 7. Two things worth knowing about precision and delivery

**Decimal precision.** A result of `4.0` is not the same statement as `4` — the
trailing zero states what the analyser measured. JavaScript has one number type,
so anything read through `JSON.parse` loses it. Every path in the bridge that
touches a measured value reads it from Postgres **as text**
(`content -> 'valueQuantity' ->> 'value'`), and writes store the **raw request
body** rather than a re-serialised object. If you re-implement this, keep that
property; it fails silently in both directions.

**One order, one delivery.** The poll reads and claims Tasks in a single
statement, so two overlapping polls cannot both receive the same order. A
delivery lease also counts attempts: a Task handed over repeatedly and never
acknowledged is the only signal that the laboratory cannot import it — OpenELIS
keeps no such counter.

---

## 8. Proving your implementation

```bash
make unit           # the pure functions: ids, name splitting, precision
make requester      # the clinician reaches the laboratory's screen
make rejection      # the refusal matrix, and catalogue drift
make panel          # a multi-analyte report arrives whole
make corrections    # corrections and retractions
```

The identity function is worth checking first if you reimplement it. These three
must agree, and they are what the sandbox asserts:

```
uuid5(DNS, "python.org")                            → 886313e1-3b8a-5372-9b90-0c9aee199e5d
uuid5(DNS, "task|137539b5-2690-46ea-b808-bcbc0d31352c") → 07e60d38-f066-5d30-8c6a-9d9acd56b930
```

---

## Where this is written down elsewhere

- [integration-guide.md](integration-guide.md) — how to build it, step by step
- [architecture.md](architecture.md) — what runs, and why
- [upstream-issues/](upstream-issues/) — the OpenELIS defects above, filed in full
- [operations.md](operations.md) — when it breaks
