# Integrating your real HIS

Step by step, for the team replacing the sandbox HIS with the production one.

Read [architecture.md](architecture.md) first if you have not — this assumes you
know what the bridge is and why it exists.

---

## What you keep, what you replace

The sandbox contains two different kinds of thing, and the distinction is the
whole point of it.

| | |
|---|---|
| **Replace** — this stood in for you | `his-api`, `his-frontend`, `his_sandbox` database |
| **Keep** — this is the integration | `bridge`, `bridge_sandbox` database, the mTLS material |
| **Keep** — infrastructure you likely already have | Kafka, Redis, Consul, Kong, the edge proxy |
| **Not yours** — the laboratory owns it | everything `openelis-*` |

**The bridge is the deliverable.** You should not have to modify it. If you find
yourself editing `OrderMapper.cs` to make your HIS fit, stop — that is a sign the
contract below is not being met, and the fix is almost certainly on your side.

---

## Step 0 — Two settings in OpenELIS, before anything else

**Neither is a code change. Both are laboratory administration, on the stock
image. Get these wrong and the integration looks broken in ways that point
nowhere near the real cause.**

### `external orders` must be `true`

**Administration → Order Entry Configuration** → `external orders`
("Allow external sites to send electronic orders").

**OpenELIS ships with this `false`**, and the failure it produces is
misleading. Orders still arrive, still import, still appear in Incoming Orders —
because the import path is server-side and this flag does not gate it. What
breaks is the **accessioning screen**: the wizard takes this branch,

```js
} else {
    setOrderFormValues(prev => ({ ...prev,
      sampleOrderItems: { ...prev.sampleOrderItems, externalOrderNumber: "" }}));
}
```

deliberately discarding the order number and never fetching the order. The lab
user sees a blank patient form and *"No patients found matching search terms"*,
with nothing to suggest a configuration flag is responsible.

**Changing it requires a restart of the OpenELIS webapp.** The save writes
`true` to the database, but the running application keeps serving the old value
— verified: the database read `true` while `/rest/configuration-properties` still
returned `"false"` until the container restarted.

### `auto-fill collection date/time` should stay `false`

Same page. With it on, an accessioner who does not know when the specimen was
drawn gets the **arrival** time stamped in as the collection time. That is worse
than a blank: it is indistinguishable from an observed value, and a clinician
will judge how current a result is by it. See
[Step 3b](#step-3b--patient-class-decides-the-collection-workflow).

---

## Step 0 — Two OpenELIS settings, before anything else

**Neither is a code change.** Both are laboratory administration on the stock
image. Get the first wrong and the integration looks broken in a way that points
nowhere near the cause.

### `external orders` must be `true`

**Administration → Order Entry Configuration** → `external orders`
("Allow external sites to send electronic orders").

**OpenELIS ships with this `false`**, and the failure is misleading. Orders still
arrive, still import, and still appear in Incoming Orders — the import path is
server-side and this flag does not gate it. What breaks is the **accessioning
screen**, which takes this branch instead of fetching the order:

```js
} else {
    setOrderFormValues(prev => ({ ...prev,
      sampleOrderItems: { ...prev.sampleOrderItems, externalOrderNumber: "" }}));
}
```

The lab user gets a blank patient form and *"No patients found matching search
terms"*, with nothing suggesting a configuration flag is responsible.

**Changing it requires an OpenELIS restart.** Saving writes `true` to the
database, but the running application keeps serving the old value — verified
here: the database read `true` while `/rest/configuration-properties` still
returned `"false"` until the container was restarted.

### `auto-fill collection date/time` should stay `false`

Same page. With it on, an accessioner who does not know when the specimen was
drawn gets the **arrival** time stamped in as the collection time — worse than a
blank, because it is indistinguishable from an observed value and a clinician
will judge how current a result is by it.

---

## Step 1 — Decide who owns the test menu

**The laboratory does.** Do not author a test catalogue in your HIS.

The bridge reads OpenELIS's enabled, orderable tests and mirrors them. Your HIS
holds a *copy* and refreshes it. That copy is what the doctor searches.

Your `test_catalogue` table needs, at minimum:

| column | example | why |
|---|---|---|
| `test_code` | `10351-5\|Plasma` | your internal handle for the row |
| `test_name` | `HIV VIRAL LOAD (Plasma)` | what the doctor reads |
| `loinc_code` | `10351-5` | **half the identity** |
| `specimen_type` | `Plasma` | **the other half** |
| `specimen_snomed` | `119364003` | optional, interoperability |
| `is_active` | `true` | set false when withdrawn — **do not delete** |

Two rules that are not negotiable:

- **Never delete a withdrawn row — deactivate it.** Orders already placed
  reference it, and they still need to resolve their test name.
- **A row is identified by `(loinc_code, specimen_type)`**, not by name. That pair
  is what the laboratory resolves an order with.

Refresh by calling the bridge:

```
POST /admin/catalogue/refresh          (operator token)
GET  /test-catalogue                   the current menu
```

Run it after the laboratory changes anything. It is deliberately manual — an
automatic sync could empty your doctors' menu at 3am because someone was editing
the catalogue.

## Step 2 — Show the menu as a search box, not a dropdown

The doctor types, matching rows appear, they pick one. The **specimen must be
visible on every row**, because `HIV VIRAL LOAD (Serum)` and
`HIV VIRAL LOAD (Plasma)` are different orders and only the doctor knows which
will be drawn.

Submit the `test_code` of the row they picked. Nothing else identifies the test.

## Step 3 — Place the order

```
POST /lab-orders
{
  "patientId":    "<uuid>",          required
  "testCode":     "10351-5|Plasma",  required — from the catalogue row
  "facilityCode": "FAC-001",         required
  "priority":     "routine",         optional: routine | asap | stat
  "visitNumber":  "V-2026-0042",     optional, but send it — see step 6
  "patientClass": "OUTPATIENT"       optional, defaults to OUTPATIENT — see 3b
}
```

Returns `orderId` and `orderNumber`. **Store the order number, and never change
it.** It is the only identifier that survives the round trip — the patient, the
visit and the test are all re-derived from the order row when the result comes
back, by joining on it. Regenerate or reuse it and the result returns
uncorrelatable: dead-lettered, published as `lab.result.failed` /
`UNCORRELATED`, and sitting in a queue instead of in front of a doctor. The
full contract is in
[integration-field-map.md §1b](integration-field-map.md#1b-the-identity-contract).

**The ordering doctor is taken from the verified token, never from the body.**
Ordering on behalf of another clinician is not supported, deliberately.

### Step 3b — Patient class decides the collection workflow

A collection time is a fact about a physical event, and **only whoever watched
it can state it**. That single rule produces two workflows, and `patientClass`
picks between them.

#### OUTPATIENT — the laboratory observes the draw

The patient walks to the laboratory and a technician draws there.

```
08:20  Doctor orders            → dispatches immediately
09:10  Technician draws         → types it into OpenELIS
                                  (sample_item.collection_date)
11:30  Released                 → comes back on Specimen.collection.collected
```

Nothing for the ward to do. **Do not send a collection time** for one of these —
you would be asserting an event you did not witness, and creating a second
version of a fact that has one observer.

#### INPATIENT — the ward observes the draw, and the order waits

A nurse draws at the bedside. Nobody in the laboratory sees it, so if you do not
capture it on the ward it is lost for good — the accessioner can only type what
someone wrote on the tube.

```
06:00  Doctor orders            → AWAITING_COLLECTION, nothing sent
06:15  Nurse records the draw   → POST /lab-orders/{orderNumber}/collection
                                  { "collectedAt": "2026-09-02T06:15:00Z" }
                                → NOW dispatches, carrying
                                  Specimen.collection.collectedDateTime
07:40  Lab accessions           → screen PRE-FILLED with 06:15
11:30  Released
```

**Why the order waits.** The draw happens after the order is placed, so the
collection time does not exist at creation — and it cannot be sent afterwards
either: once OpenELIS imports a Task it moves the status off `requested` and
never polls it again. Holding is also the honest position; until the tube exists
there is nothing for the laboratory to act on.

The collection time and the dispatch commit in **one transaction**. Either alone
is a failure retrying cannot fix: a time with no dispatch strands the order with
a nurse believing it is done, and a dispatch with no time loses the only reason
the order was waiting.

Two refusals to expect, both deliberate: recording a draw against an
**outpatient** order is a 400, and recording the same draw **twice** is a 400
rather than a silent re-send.

**The inpatient path is optional.** If your wards will not reliably record draw
times, order everything as `OUTPATIENT` and take whatever the laboratory
captures. A missing collection time displayed as *"not recorded"* is honest; a
half-used workflow that sometimes holds orders nobody comes back to is not.

## Step 4 — Publish the event

Your API writes the order row and an outbox row **in one transaction**, and a
relay publishes to `lab.order.created`. Do not publish directly from the request
handler: if the broker is down you must still accept the order, and the outbox is
what makes that safe.

The bridge consumes from there. That is the entire coupling between your HIS and
the integration — one topic.

## Step 5 — What the bridge sends onward

You do not need to build this; it is what happens next, and knowing it makes the
failures legible. Five FHIR resources: `Patient`, `Specimen`, `ServiceRequest`,
`Task`, and a `Practitioner` representing the laboratory.

From the patient record it carries **name, sex, date of birth, national id and
phone**. Sex and date of birth are not optional in practice — OpenELIS selects
reference ranges with them, so a wrong date of birth produces a wrong
interpretation, not a cosmetic error.

Deliberately **not** sent: the file number/MRN, the ordering clinician, the
requesting organisation, and the visit number. Full reasoning in
[integration-field-map.md](integration-field-map.md).

## Step 6 — Receive results

```
GET /patients/{id}/results
GET /visits/{visitNumber}/results
```

Each result carries `orderNumber` and `visitNumber`, so you can file it against
**the right visit and the right order** — including when one visit has several
orders, which is the normal case.

`specimenType` is not decoration: two orders for the same LOINC on different
specimens share a `testName` — "HIV VIRAL LOAD" for both plasma and dried blood
spot — and are different examinations with different methods and reference
ranges. Show it, or your clinicians cannot tell the two apart.

**Show `labAccession` next to `orderNumber`.** They are the two numbers a person
quotes, and they are quoted to different people: `orderNumber` identifies the
order in *your* system, `labAccession` identifies it in the *laboratory's*. When
a ward telephones the lab about a result, only the second one can be looked up
by whoever answers. It is null until a lab user accessions the sample, because
no accession number exists before the laboratory has taken the specimen in.

```json
{
  "orderNumber":         "LAB-20260825-59088EB0",
  "visitNumber":         "V-2026-0042",
  "testName":            "HIV VIRAL LOAD",
  "specimenType":        "Plasma",
  "resultValue":         "42",
  "resultUnit":          "copies/mL",
  "referenceRange":      "3.9-5.8",
  "interpretation":      "High",
  "interpretationCode":  "H",
  "resultStatus":        "corrected",
  "previousValue":       "13.8",
  "previousReleasedAt":  "2026-08-14T09:15:00Z",
  "collectedAt":         "2026-08-14T06:15:00Z",
  "collectionSource":    "ward",
  "labAccession":        "DEV0126000000000004",
  "openelisResultRef":   "…"
}
```

The MRN is not in there and does not need to be — resolve it from `patientId`,
which you own.

Neither the patient id nor the visit is read back from what the laboratory
returns; both are joined from the order row that `orderNumber` identifies. That
is what makes filing correct even when results arrive out of order, or when a
correction lands weeks after the encounter closed —
[§1b](integration-field-map.md#1b-the-identity-contract).

**Show `collectedAt` next to `releasedAt`, and never substitute one for the
other.** A result released five minutes ago may be from blood drawn six hours
ago, and release time alone cannot say so. `collectionSource` tells you which
system observed the draw — `ward` or `laboratory`. When both are absent, display
**"not recorded"**: a blank cannot be told apart from a rendering fault, and a
fabricated collection time is indistinguishable from an observed one, so a
clinician will act on it.

> **Trap.** Do not read the collection time from `Observation.effective`. FHIR
> convention says `effective` is the diagnostically relevant time and US Core
> describes it as *"typically the time of specimen collection"* — but OpenELIS
> sets it to `analysis.getReleasedDate()`, falling back to `getStartedDate()`
> (`FhirTransformServiceImpl`). Following the specification here gets you the
> release time: a plausible timestamp, hours wrong, with nothing failing. The
> real value is on the `Specimen` the report references.

Results can be **corrected after release**. Treat `resultStatus` as a state, keep
the history, and never overwrite a previous value in place.

### Step 6b — Corrections need an alert, not a badge

**This is the one place where doing what the sandbox does is not enough.**

A laboratory does not only publish results — it corrects and withdraws them, and
the evidence on what happens next is unusually clear:

- a chart review of 480 corrected microbiology reports found **6.7% caused
  measurable adverse clinical impact** — delayed therapy, unnecessary therapy,
  inappropriate therapy, or an increased level of care
- an AHRQ patient-safety review puts roughly **30% of amended values as changing
  patient care**, and names the mechanism directly: *"clinicians are not
  anticipating a change in information"*
- a study of amended surgical pathology reports found the same failure again,
  and located it precisely: the correction existed in the LIS and **did not
  reach the treating clinician**

Note where that failure sits. Not in the laboratory, which did its job. Not in
the interface, which delivered the message. In the **last hop** — getting a
doctor who has already moved on to look again.

#### What the integration guarantees you

The bridge publishes every correction as its own `lab.result.released` event with
`resultStatus` set to `corrected` or `amended`, keyed by `meta.versionId` so a
genuine new version is never suppressed as a duplicate. Corrections arrive as
distinct, ordered, at-least-once events. **You will be told.**

The sandbox frontend then shows the new value, a `corrected` badge, and the
superseded value beneath it (`previousValue`). That satisfies ISO 15189 7.4.1.8
— a revised report must reference what it revised — and it is where a
demonstration stops.

#### What your HIS must add

A badge only works on a clinician who happens to be looking at the screen. The
studies above describe clinicians who are not. So the correction has to **go
find them**:

1. **Raise a task, notification or inbox item** addressed to the ordering
   clinician — `lab_orders.ordering_provider_id`, recorded from the verified
   token, is exactly who to route it to.
2. **Require acknowledgement.** A notification that can be scrolled past is a
   badge with extra steps. The clinician should have to dismiss it.
3. **Escalate if it is not acknowledged.** The doctor may be off shift. Route to
   the covering clinician or the ward, the same way a critical value is escalated
   when the responsible person cannot be reached (ISO 15189 7.4.1.3(c)).
4. **Treat a retraction (`entered-in-error`) at least as seriously as a
   correction.** A withdrawn result is one the clinician may have acted on and
   which no longer exists. It is not a quieter event than a correction; if
   anything it is louder.
5. **Alert on the critical tier separately.** `interpretationCode` carries the
   HL7 code, where `AA` / `HH` / `LL` mean *critically* abnormal rather than
   merely abnormal. Never key this off the display wording — `interpretation`
   holds the laboratory's own text and it is free to change; a severity rule
   that matches on the word "critical" fails silently the day it becomes
   "panic". CLIA 42 CFR 493.1109(f) and ISO 15189 7.4.1.3 both oblige the
   laboratory to telephone a critical value; a HIS that renders it with the
   same visual weight as a routine result defeats a notification the laboratory
   is legally obliged to make.

#### What not to do

**Do not suppress the old value.** A clinician who acted on 13.8 needs to see
13.8 to judge whether that decision still stands. ISO 15189 7.4.1.8 requires the
revised report to identify the original; the operational guidance is explicit
that previous results and interpretations are replicated *precisely because
decisions may have been based on them*. Showing only the corrected number is the
pattern the literature associates with missed-correction harm.

**Do not treat a new resource id as the signal.** FHIR corrections update the
*same* Observation with a new `status` and an incremented `meta.versionId`. A
HIS watching for new ids will not see corrections at all.

## Step 7 — Handle the unhappy paths

Your HIS must react to four outcomes, not one:

| status | meaning | what to do |
|---|---|---|
| `AWAITING_COLLECTION` | **the laboratory has heard nothing** — an inpatient order waiting on a bedside draw | not a fault: put it on the ward's worklist. Nothing will move it but a nurse |
| `REJECTED_BY_LIS` | the laboratory refused the order | show the doctor the reason; it is in `status_detail` |
| `FAILED` | the bridge refused to send it | usually a stale catalogue — re-sync, re-order |
| no result after a long time | nobody has accessioned it | needs a human; there is no automatic timeout today |

`AWAITING_COLLECTION` is the one that looks like a stall and is not. Every other
waiting state means a system has the order and has not finished with it; this one
means **nothing has been sent** — no event, no Task — because the specimen does
not exist yet. Triage it as a ward question, never as an integration incident.

There is deliberately no timeout on it. Expiring a real pending order because a
nurse was busy would be worse than leaving it visible, so **build an escalation
on top of that queue** rather than expecting the sandbox to clear it.

**Known ambiguity, and you should design around it:** OpenELIS reports
`rejected` both when the laboratory genuinely declines a test **and** when it hits
an internal storage error. They are indistinguishable from outside. Do not tell a
clinician "the laboratory refused this" with certainty — say the order did not
complete and needs review. This is filed upstream as
[defect 01](upstream-issues/01-task-poll-not-idempotent.md).

## Step 8 — Match the infrastructure contracts

The bridge already speaks these; your services should too.

- **Health** — `GET /health` returning the same document shape, so one probe
  works everywhere
- **Consul** — register with the same naming and health-check convention
- **Metrics** — `/metrics` in Prometheus format, same metric names
- **Logs** — structured JSON, and **propagate the correlation id**: it is what
  lets you follow one order across the HIS, Kafka, the bridge and OpenELIS

The correlation id is the single most useful thing here. Carry it through
everything.

## Step 9 — Prove it

Run the suites against your stack. They are the specification in executable form:

```
make smoke           platform and wiring
make catalogue-test  the menu, and the specimen abbreviations
make e2e             a real order into OpenELIS  (pauses for the lab step)
make results         the return path
make rejection       refusal and drift
make negative        outages: broker, Redis, API, OpenELIS
make auth            tokens, revocation, degraded mode, audit
```

If `catalogue-test` fails, stop. A catalogue problem produces **silently wrong
test binding**, which is worse than an outage because nothing looks broken.

---

## From integration to production

Everything above gets orders flowing correctly. None of it makes the system fit
to run a real laboratory. That is a different body of work, and it is mostly
operational rather than integration.

**The integration logic is production-grade — the deployment is not.** The gaps
below are infrastructure decisions your organisation makes. None are blocked by
anything in this repository, and none change the contract above.

**Make the event backbone survivable.** Kafka runs here as a **single broker,
replication factor 1, min in-sync replicas 1**. An order accepted by your HIS but
not yet delivered exists only as a Kafka event plus an outbox row — so that one
broker's disk is a place where clinical work can be lost. Production wants three
brokers, replication factor 3, min ISR 2. This is the single most important item
on this list.

**Replace every credential.** The sandbox ships demo values: the bridge
authenticates to OpenELIS with the stock default administrator password, and the
databases use throwaway passwords committed in `.env.example`. Move all of them
into a real secrets manager with rotation. Note one constraint you may not be able
to remove: OpenELIS gates its catalogue endpoints behind `hasRole('ADMIN')`, so a
least-privilege service account may not be possible without upstream help — treat
that account as highly privileged and monitor its use.

**Remove the single points of failure.** One bridge, one API, one Redis, one of
each database. Run at least two of each stateless service behind a load balancer.
The bridge is safe to run multiply — its delivery lease is a database-backed
atomic claim, so two instances will not deliver the same order twice.

**Back it up, and prove the restore.** There are no backups here at all. All three
databases need scheduled backups and — the part people skip — a **restore
rehearsed on a schedule**. An untested backup is a belief, not a control.

**Watch it, and wake someone.** `/metrics` is exposed and the audit tables exist,
but nothing ships them anywhere and nothing pages anyone. At minimum, alert on:
orders stuck undelivered, the dead-letter queue growing, the catalogue sync
failing, and OpenELIS not polling. That last one is quiet by nature — the
integration looks healthy while nothing moves.

**Use real certificates.** The mTLS between bridge and OpenELIS uses a CA we
generate. That is genuine mutual authentication and worth keeping, but the
material needs to come from your PKI with a documented rotation procedure —
including the fact that OpenELIS reads its truststore **once at startup**, so
rotation means a restart.

**Decide the unacknowledged-order policy.** There is deliberately no timeout on an
order OpenELIS never acknowledges. The bridge counts delivery attempts, so the
condition is *visible*, but nobody is told. Decide how long is too long and who
gets called.

**Keep validating the patch.** If you run the patched OpenELIS build
(`OE_IMAGE_REPO=his-sandbox`), that patch must be re-applied, re-verified in the
compiled artefact and re-validated against the full suite at **every** upgrade,
for as long as you carry it. The procedure is in
[openelis-patches/README.md](../openelis-patches/README.md). The default is stock,
and staying stock is cheaper.

**Involve the laboratory.** Two things in this list are theirs, not yours: keeping
the test catalogue clean — a LOINC mapped to two different analytes is a mapping
error that removes tests from your doctors' menu — and understanding that
disabling a test in OpenELIS changes what your HIS can order at the next sync.
That conversation is worth having before go-live rather than after.
