# Integrating your real HIS

Step by step, for the team replacing the sandbox HIS with the production one.

Read [architecture.md](architecture.md) first if you have not. This guide is the
*order of work*; [integration-contract.md](integration-contract.md) is the field
reference. When the two overlap, the contract is the authority on what a message
looks like and this document is the authority on what to do about it.

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
yourself editing `order.mapper.ts` to make your HIS fit, stop — that is a sign
the contract is not being met, and the fix is almost certainly on your side.

---

## Step 0 — Two OpenELIS settings, before anything else

**Neither is a code change.** Both are laboratory administration on the stock
image. Get the first wrong and the integration looks broken in a way that points
nowhere near the cause.

Both are readable at runtime from `GET /rest/configuration-properties`, which is
how the values below were confirmed on this stack.

### `ACCEPT_EXTERNAL_ORDERS` must be `true`

**Administration → Order Entry Configuration** → `external orders`
("Allow external sites to send electronic orders").

**OpenELIS ships with this `false`**, and the failure is misleading. Orders still
arrive, still import, and still appear in Incoming Orders — the import path is
server-side and this flag does not gate it. What breaks is the **accessioning
screen**, which branches on it:

```js
ACCEPT_EXTERNAL_ORDERS === "true"
  ? V(new URLSearchParams(window.location.search).get("ID"))     // load the order
  : m(e => ({ ...e, sampleOrderItems: { ...e.sampleOrderItems,
                                        externalOrderNumber: "" } }))
```

With the flag on, the screen reads the order id out of the `ID` query parameter
and fetches it. With it off, it blanks the field and fetches nothing: the lab
user gets an empty patient form and *"No patients found matching search terms"*,
with nothing suggesting a configuration flag is responsible.

**Changing it requires an OpenELIS restart.** Saving writes `true` to the
database, but the running application keeps serving the old value — verified
here: the database read `true` while `/rest/configuration-properties` still
returned `"false"` until the container was restarted.

### `AUTOFILL_COLLECTION_DATE` should stay `false`

Same page. With it on, an accessioner who does not know when the specimen was
drawn gets the **arrival** time stamped in as the collection time — worse than a
blank, because it is indistinguishable from an observed value and a clinician
will judge how current a result is by it. See [Step 3b](#step-3b--patient-class-decides-the-collection-workflow).

### While you are in there

Two more properties change what your HIS must send, and both are per-site:

- **`PATIENT_NATIONAL_ID_REQUIRED`** is `true` on this stack. A patient with no
  national id will not accession.
- **`FIRST_NAME_REGEX` / `LAST_NAME_REGEX`** decide which names the laboratory
  will accept at all. See [Names](#names-go-in-latin-script-and-carry-no-digits).

---

## Step 1 — Decide who owns the test menu

**The laboratory does.** Do not author a test catalogue in your HIS.

OpenELIS holds the real menu. The bridge mirrors it. Your HIS holds a *copy* of
the bridge's mirror, and that copy is what the doctor searches.

Your `test_catalogue` table needs, at minimum:

| column | example | why |
|---|---|---|
| `test_code` | `10351-5\|Plasma` | your internal handle for the row |
| `test_name` | `HIV VIRAL LOAD (Plasma)` | what the doctor reads |
| `loinc_code` | `10351-5` | **half the identity** |
| `specimen_type` | `Plasma` | **the other half** |
| `specimen_snomed` | `119364003` | optional, interoperability |
| `is_active` | `true` | set false when withdrawn — **do not delete** |

Three rules that are not negotiable:

- **A row is identified by `(loinc_code, specimen_type)`**, not by name. That pair
  is what the laboratory resolves an order with.
- **Never delete a withdrawn row — deactivate it.** Orders already placed
  reference it, and they still need to resolve their test name. Note that the
  bridge's own mirror does the opposite — it hard-deletes on every sync, because
  nothing holds a foreign key into it. Yours holds order history; do not copy
  that behaviour.
- **Never split `test_code` on `|` to recover the specimen.** It looks
  decomposable because newly discovered codes are synthesised as
  `` `${loinc}|${specimenName}` ``, but locally seeded single-specimen tests keep
  a bare code like `GLUC`. Read `specimen_type` from its own column.

### Refreshing is two calls, not one

This trips people, because the first one is easy to skip and skipping it looks
like success.

```
POST  /catalogue/sync            on the BRIDGE    OpenELIS → bridge
POST  /admin/catalogue/refresh   on HIS-API       bridge   → your HIS
```

The second reads whatever the bridge already had. Run it alone and you will
faithfully mirror a stale menu and be told `applied: true`. `make sync-catalogue`
runs both, in order, and prints the diff of each.

Two guards sit on the bridge half, and both refuse rather than apply:

| Guard | Refusal |
|---|---|
| zero tests discovered | far more likely to be a failed login than an empty laboratory |
| the menu shrank by more than `CATALOGUE_MAX_SHRINK` (default 30%) | one bad sync must not silently empty your doctors' menu |

A refused sync returns **409** and leaves the previous menu untouched. Override
with `?force=true` (`make sync-catalogue FORCE=true`) once you have looked at why.
The HIS half has a guard of its own: if the bridge has no catalogue at all it
returns 409 rather than deactivating everything.

Refresh after the laboratory changes anything. It is deliberately manual — an
automatic sync could empty the menu at 3am because someone was mid-edit.

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
  "patientId":    "<uuid>",          required — must parse as a UUID
  "testCode":     "10351-5|Plasma",  required — from the catalogue row
  "facilityCode": "FAC-001",         required — a site from GET /facilities
  "priority":     "routine",         optional, default routine; lowercased, not enumerated
  "visitNumber":  "V-2026-0042",     optional, max 64 chars — but send it, see step 6
  "patientClass": "OUTPATIENT"       optional, default OUTPATIENT — UPPERCASE only
}
```

Returns **201** with the order, and `Location: /lab-orders/{orderId}`.

Four refusals, all **400**, all checked in this order: unknown or inactive
`testCode`; unknown `patientId`; unknown or inactive `facilityCode`; and
`orderingProvider` present at all (see below).

> **One rough edge worth smoothing in your own API.** The field-specific messages
> — *"patientId must be a uuid."* — only fire when a key is **present and
> wrong**. Omit a required key entirely and the body is a bare
> `{"status": false, "message": "Required", "data": null}` with no field name.
> Also: `GET /lab-orders/{id}` with a non-UUID is a **500**, not a 404, because
> Postgres raises before any handler sees it.

### The order number is the identifier that matters

**Store it, and never change it.** It is the only identifier that survives the
round trip — patient, visit and test are all re-derived from your order row when
the result comes back, by joining on it. Regenerate or reuse one and the result
returns uncorrelatable: dead-lettered, published as `lab.result.failed` /
`UNCORRELATED`, and sitting in a queue instead of in front of a doctor.

The sandbox mints `LAB-YYYYMMDD-XXXXXXXX`. Yours can look like anything that
satisfies all three constraints:

| Constraint | Where it comes from |
|---|---|
| unique for all time | it is the correlation key |
| **≤ 60 characters** | OpenELIS truncates `electronic_order.external_id` there |
| matches `[A-Za-z0-9-.]{1,64}` | it becomes `ServiceRequest.id`, and that is the FHIR id grammar |

Underscores, spaces and slashes are **not** in that grammar. A number containing
one is rejected by the FHIR store rather than by anything of ours.

The full identity contract is in
[integration-contract.md](integration-contract.md#trust-your-own-order-row-not-the-message).

### The clinician is never in the body

**The ordering doctor is taken from the verified token.** Ordering on behalf of
another clinician is not supported, deliberately — and the API does not merely
ignore an attempt, it refuses it:

```
400  orderingProvider is not accepted: the ordering clinician is taken
     from your session, not from the request body.
```

That is on purpose. Silently stripping the field would let a caller believe they
had named a doctor while the order carried someone else. Copy the refusal, not
just the rule. The reasoning runs through [Step 4a](#step-4a--if-your-workflow-sits-between-the-order-and-the-publish).

### Step 3a — Where the order came from

`facilityCode` must name a site from `GET /facilities`; an unknown one is refused
with 400. The check is deliberately not a foreign key — it is validated on the
way in and then left alone, so a site can be retired without rewriting history.

This is the laboratory's **Referring Site**: who sent the sample, where the
report goes back, and who they telephone about a problem.

**`his.facilities` is a sandbox stand-in. Do not build this table.** The
referring site already exists in your estate, in more than one shape.
`mlh_his_org_setup_branches` and `mlh_his_org_setup_wards` both carry exactly
what is needed — a `code`, a `name`, an `is_active` flag — and each is the right
answer for a different order:

| The order was placed… | Referring site | Why |
|---|---|---|
| in a clinic or outpatient department | `mlh_his_org_setup_branches.code` | the site is where the patient attended |
| at an inpatient bedside | `mlh_his_org_setup_wards.code` | a patient moves between wards, and the report has to reach the one they were on when it was ordered — `mlh_his_sys_patient_locations` knows which |
| and you only know the department | `mlh_his_org_setup_business_units.code` | `mlh_his_iam_usr_vs_bunits` already ties the signed-in user to it, so nobody has to be asked |

`his.facilities` flattens all three into one list of codes. That is fine for a
sandbox and wrong for the estate: branches, wards and business units are
maintained separately and mean different things. **Send the code from whichever
of the three the order actually came from.**

#### Carrying it to the laboratory

Today the facility reaches `his.lab_orders` and the bridge, and stops there —
`order.mapper.ts` does not reference it, and it appears in none of the resources
we publish. Until it does, the Referring Site is typed by hand at accessioning on
every order.

Closing that is a change to the mapper, and the deployed OpenELIS 3.2.2.0
bytecode says exactly what it has to send. There are **two** routes in, and they
are not equally cheap:

**Route A — `Task.restriction.recipient[0]`, an Organization.** On the
accessioning screen, `LabOrderSearchProvider` reads that reference, fetches it
from our FHIR store as an `Organization`, and then resolves it locally with
`organizationService.getOrganizationByFhirId(...)`.

Note *which* column that is. The lookup is on **`organization.fhir_uuid`**, not
on `organization.code`. A laboratory administrator has to create one row per site
whose `fhir_uuid` equals the UUID you reference. The `code` column plays no part
in this path.

**Route B — `Task.location`, a Location. This one needs no laboratory admin at
all.** On import, `FhirApiWorkFlowServiceImpl` resolves `Task.location`, and if
no organization already carries that UUID it creates one:

```java
Organization org = organizationService.getOrganizationByFhirId(
                       location.getIdElement().getIdPart());
if (org == null) {
    org = new Organization();
    if (location.hasName()) org.setOrganizationName(location.getName());
    org.setFhirUuid(UUID.fromString(location.getIdElement().getIdPart()));
    org.setIsActive("Y");
    org.setMlsLabFlag("N");
    org.setMlsSentinelLabFlag("N");
    organizationService.save(org);
    organizationService.linkOrganizationAndType(
        org, TableIdService.getInstance().REFERRING_ORG_TYPE_ID);
}
```

`REFERRING_ORG_TYPE_ID` resolves by name to the `referring clinic` organization
type — id 5 in this database. And the accessioning-screen code closes the loop:
when the recipient path yields nothing, `addRequestingOrg` falls back to
`Task.location` and looks it up by the same `fhir_uuid`, emitting the
organization's internal id and name for the wizard to prefill.

So the whole mechanism is:

1. Give every referring site a **stable UUID** — one you mint once and keep.
2. Publish a `Location` with that id and the site's name in `Location.name`.
3. Reference it from `Task.location`.

First import creates the referring organization, named correctly, active, and of
the right type. Every import after that prefills the Referring Site.

#### Proven on this stack

Not inferred — run end to end on 15 September 2026 against stock OpenELIS
3.2.2.0, with **no laboratory administration of any kind**. A `Location` named
`Obygaine Dermatology` was published to the bridge's FHIR store, referenced from
`Task.location`, and one order placed.

OpenELIS imported it 35 seconds later and created the organization itself:

```
 id |         name          | code | fhir_uuid                            | org_type
  4 | Obygaine Dermatology  | null | e319a15a-0c34-413a-9f12-65463fa0eefa |    5
```

Type 5 is `referring clinic`. Note `code` is **null** — further confirmation that
this path has nothing to do with the `code` column.

The accessioning screen then received it. Querying the endpoint the wizard itself
calls, `ajaxQueryXML?provider=LabOrderSearchProvider&orderNumber=…`:

```json
"requestingOrg": { "fhir-id": "e319a15a-0c34-413a-9f12-65463fa0eefa",
                   "name": "Obygaine Dermatology",
                   "id": 4 }
```

and the React form maps that straight onto the field the technician would
otherwise type:

```js
K = (e, t) => { e.sampleOrderItems = { ...e.sampleOrderItems,
                                       referringSiteId: t.id }; … }
//  called as:  n.requestingOrg && K(r, n.requestingOrg)
```

So all three links hold: Location → organization row → prefilled Referring Site.

> **One caution that remains.** `UUID.fromString` on the Location id is
> unguarded, exactly as it is for `Practitioner.id` — a non-UUID site code like
> `FAC-001` throws inside the import and the order never lands. The id must be a
> UUID; put your own site code in `Location.identifier` if you want it carried.

### Step 3b — Patient class decides the collection workflow

A collection time is a fact about a physical event, and **only whoever watched it
can state it**. That single rule produces two workflows, and `patientClass` picks
between them. It is **case-sensitive** over HTTP — `"inpatient"` is refused.

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

Note the path is keyed on the **order number**, not the order id.

**Why the order waits.** The draw happens after the order is placed, so the
collection time does not exist at creation — and it cannot be sent afterwards
either: once OpenELIS imports a Task it moves the status off `requested` and
never polls it again. Holding is also the honest position; until the tube exists
there is nothing for the laboratory to act on.

The collection time and the dispatch commit in **one transaction**, opened with a
`SELECT … FOR UPDATE` on the order row so two nurses cannot both pass the status
check and queue two dispatches. Either half alone is a failure retrying cannot
fix: a time with no dispatch strands the order with a nurse believing it is done,
and a dispatch with no time loses the only reason the order was waiting.

Four refusals to expect, all **400** and all deliberate:

| Condition | Why it is refused |
|---|---|
| the order is **outpatient** | the laboratory observes and reports that collection itself |
| the order is not `AWAITING_COLLECTION` | its collection has already been recorded |
| `collectedAt` is in the future | tolerating 60 seconds of clock skew, and no more |
| the test has left the catalogue | it cannot be dispatched, so recording a draw would mislead the nurse |

An **unknown order number is also 400, not 404** — worth knowing before you build
error handling that keys on the status code.

**The inpatient path is optional.** If your wards will not reliably record draw
times, order everything as `OUTPATIENT` and take whatever the laboratory
captures. A missing collection time displayed as *"not recorded"* is honest; a
half-used workflow that sometimes holds orders nobody comes back to is not.

## Step 4 — Publish the event

Your API writes the order row and an outbox row **in one transaction**, and a
relay publishes to `lab.order.created`. Do not publish from the request handler:
if the broker is down you must still accept the order, and the outbox is what
makes that safe.

The bridge consumes from there. That is the entire coupling between your HIS and
the integration — one topic, carrying **ids only**:

```json
{
  "eventId":     "<uuid>",
  "eventType":   "lab.order.created",
  "occurredAt":  "2026-09-15T06:34:00.000Z",
  "correlationId": "<uuid>",
  "orderId":     "<uuid>",
  "orderNumber": "LAB-20260915-137539B5",
  "patientId":   "<uuid>",
  "testCode":    "10351-5|Plasma",
  "loincCode":   "10351-5"
}
```

No demographics travel on the topic. The bridge fetches the rest over
`GET /internal/lab-orders/{orderId}` with an internal key, so the patient's name
is never sitting in a Kafka log.

**`eventId` is the idempotency key, and it is yours to get right.** The bridge
claims each one with `INSERT … ON CONFLICT (event_key) DO NOTHING` before doing
any work. Omit it and the fallback key is `topic:partition:offset`, which changes
if the topic is ever rebuilt. Reuse one across genuinely different orders and the
second order is silently dropped as a duplicate. Mint a fresh UUID per event.

Delivery is **at-least-once** by design. The relay claims rows with
`FOR UPDATE SKIP LOCKED`, and on a publish failure it records the error and
**stops the batch** rather than skipping ahead — so a later event for one order
can never overtake an earlier one.

### Step 4a — If your workflow sits between the order and the publish

**Read this if the order does not go to Kafka the moment the doctor places it.**

In this sandbox those are the same instant, because there is one screen and no
workflow. A real HIS has one: insurance verification, fulfilment, approval. The
order is written when the doctor decides, and published only once all of that
clears — which may be ninety seconds later for a fully insured patient, or three
days later for one waiting on an approval, or never, if the order expires and a
supervisor re-creates it.

**Publish once, at the end.** What goes on `lab.order.created` is the order that
has been through the whole workflow and come out approved — not a doctor's
keystroke, and not one event per workflow transition. Read the topic name as
*"this order is ready for the laboratory"*. Everything before that is yours: an
order awaiting insurance has no business in a laboratory's queue, and an expired
one that nobody approved must never arrive there at all.

**That variability is the whole danger.** The rule:

> Once the order row exists, the ordering clinician is read **from the order
> row**. Never from the session of whoever advances the workflow.

**One rule, three cases.** The gap is not always the same length or shape:

| | What happens | Read from the row | Read from the session |
|---|---|---|---|
| **A · auto-approved** | insured for everything, ~10 seconds | the doctor ✅ | the doctor ✅ — *or `undefined` if a background job* |
| **B · approved by a person** | same order row, staff clear the insurance | the doctor ✅ | **the approver** ❌ |
| **C · expired, re-created** | new order, clinician copied from the old one | the doctor ✅ | **the supervisor** ❌ |

Case **A is what makes this hard to catch** — reading the session gives the right
answer, so testing an insured patient shows the doctor's name and the code looks
correct. It is coincidentally right, and stops being right for B and C.

B and C are different actions: **approval must not write the clinician columns at
all** (it changes a status; there is nothing to carry, it is the same row), while
**re-creation copies them** from the order being replaced, under a new order
number.

**Whichever service publishes to Kafka owns this rule** — not necessarily the one
that created the order. The publishing service is the one with an authenticated
approver in scope, which is exactly why it is the one that will reach for
`req.user`. In the creating service the signed-in user genuinely is the doctor,
so nothing goes wrong there.

The failing version is one plausible line in whichever service finally publishes:

```ts
// ❌ WRONG — req.user at dispatch is whoever advanced the workflow:
//    the nurse, the receptionist, the supervisor who approved it
const clinician = req.user.hcp_id;

// ✅ RIGHT — read what the doctor's order already says
const { rows } = await client.query(
  `SELECT ordering_provider, ordering_provider_hcp_id, ordering_provider_license
     FROM his.lab_orders WHERE order_id = $1`, [orderId]);
const clinician = rows[0].ordering_provider_hcp_id;
```

The word **request** in `req.user` is the trap: it means *"whoever is making this
HTTP call right now"*, and at dispatch that is not the doctor. Nobody is asked to
prove anything at this point — the code reads a name off a row, the way a
pharmacist reads the prescriber off a prescription instead of telephoning the
surgery.

Three identities sit close together at that moment. Only one is the answer:

| | Holds | At dispatch |
|---|---|---|
| `lab_orders.ordering_provider_hcp_id` | the clinician who decided | ✅ **read this** |
| `lab_orders.ordering_provider_id` | that doctor's login account | audit trail only |
| `req.user.hcp_id` | whoever is signed in *now* | ❌ never |

`ordering_provider_hcp_id` is written **once**, at creation, from the doctor's
verified token — and never written again.

It will pass every test you write. For an insured patient the doctor places the
order and the approval clears in a minute, often in the same session, so the
clinician looks correct. The bug only appears when the two are different people —
which is precisely the delayed, re-created, insurance-held order, the one that
has already waited three days and is least likely to be looked at closely. The
laboratory is then told a receptionist ordered a potassium, and if it comes back
critical they telephone the front desk.

The contract, stated once:

| Step | Clinician | Actor |
|---|---|---|
| Doctor places the order | from the **verified token**, written once | the doctor |
| Insurance / fulfilment / approval | **read from the order row** | recorded in the audit trail |
| Expiry and re-creation | **inherited from the order being replaced** | the supervisor, in the audit trail |
| Publish to Kafka | **read from the order row** | the relay, which has no user |

The actor of each step belongs in the audit trail. It never belongs on the order.
A supervisor re-creating an expired order is performing a clerical act on a
clinical decision someone else already made and recorded — which is why this does
not conflict with the rule that a caller may never name a clinician. They name an
**order**; the clinician comes with it.

**The doctor's token will not survive the wait, and must not need to.** It
expires on its 24-hour TTL; the estate keeps one session per user, so the doctor
signing in on a second device ends the first; and they may have logged out or
gone off shift. There is nothing to re-authenticate against at dispatch — which
is exactly why `req.user` is tempting there, and exactly why it is wrong.

Authentication asks *"are you who you claim, right now?"* and lasts as long as a
session. Attribution asks *"who decided this, then?"* and lasts as long as the
record. The clinician on an order is attribution: verified once, when the doctor
was present, and a recorded fact from that moment on. Nothing downstream needs
the doctor's session, because nothing downstream is claiming to be the doctor.

Two things this rules out, both of which get invented by someone trying to make
the identity "survive": **storing the doctor's token to replay later** — a bearer
credential valid across your whole estate, sitting in a workflow table for three
days — and **a service impersonating the doctor** to publish on their behalf. The
relay that publishes has no user at all, and that is correct.

**How to test it**, since a same-session run cannot fail: place an order as a
doctor, advance and publish it as a *different* user, and assert the published
`Practitioner` is still the doctor's. That is what `make requester` does.

Two notes on the re-creation itself:

- **Mint a new order number.** OpenELIS keys `electronic_order.external_id` on
  it, and the bridge's resource ids are deterministic on the order id — re-using
  a number is read as an update to the existing order, not a new one.
- **Do it before dispatch and the laboratory never needs to know.** Nothing was
  published, so there is nothing there to duplicate or withdraw. This matters
  because you *cannot* withdraw one afterwards: OpenELIS's cancellation path is
  unreachable over FHIR
  ([defect 06](upstream-issues/06-fhir-cannot-cancel-an-order.md)).

## Step 5 — Which identity to send

You do not build what the bridge publishes — [integration-contract.md §2](integration-contract.md)
has the resources field by field. One decision inside it is yours, and it is the
one people get wrong, because both values are available and only one is correct.

Your estate keeps them in two different services:

```
IAM                          HIS-org-setup-service
  usr_id  ──────────────────►  mlh_his_hcp_health_care_provider
  the ACCOUNT that signed in     id              ← the CLINICIAN
                                 usr_id          ← nullable link back
                                 license_number
                                 name
```

**Send `hcp.id`.** Three properties of your own schema decide it:

| | Consequence |
|---|---|
| `hcp.usr_id` is **nullable** | A visiting consultant or referring physician exists as a provider with no login. Key on the account and those clinicians have no identity to send at all |
| it has **no unique constraint** | Nothing stops two provider rows sharing one `usr_id`. A key that can collide is not a key |
| your clinical record already uses `hcp.id` | `mlh_his_sys_patient_locations.ih_hcp_hcp_id` names the attending doctor that way. Send the account and the laboratory's view of "which doctor" cannot be lined up with your own |

An account is a thing someone logs into. A provider is a person accountable for a
test. The laboratory needs the second.

**This does not weaken the rule that a caller may never name a clinician.** Both
identities come from the same verified token:

```
verified token → usr_id → provider row → hcp.id → FHIR Practitioner
```

The token still decides which account acted. `hcp.id` is the correct name for the
person behind it. Nothing is read from a request body.

**Keep both columns.** They answer different questions, and collapsing them is
what made this wrong in the first place:

| Column | Answers | Read by |
|---|---|---|
| `ordering_provider_id` (`usr_id`) | which **account** placed this order | your audit trail |
| `ordering_provider_hcp_id` (`hcp.id`) | which **clinician** is accountable | the laboratory |

**When the signed-in user has no provider row** — a receptionist, a ward clerk —
publish no clinician. The order still goes; the account is not substituted for a
doctor. A login printed on a laboratory report as though it were a person is a
false clinical attribution, and worse than an empty field. `make requester` §6
covers exactly this.

### The name, and the licence

`hcp.name` is a **single column**, not given/family, so the bridge splits on
whitespace — last token to `family`, the rest to `given`. Two consequences:

- **The laboratory keeps the first name it sees.** OpenELIS copies the
  `Practitioner` on first import and never refreshes it, so a name corrected in
  your HIS will not reach the laboratory
  ([defect 05](upstream-issues/05-practitioner-name-never-refreshed.md)). Worth a
  rule for your team: write `hcp.name` the way it should appear on a laboratory
  report, first time.
- **The `Practitioner` id is a UUID derived from `hcp.id`**, never from the name.
  OpenELIS parses that id with `UUID.fromString` and no guard, so a raw numeric
  id crashes the accessioning wizard; and a name-derived identity makes every
  spelling of one doctor a separate clinician in the laboratory's records.

`license_number` goes as a **second identifier**. `hcp.id` means nothing outside
your estate; a licence number is what a technician reconciling provider records
recognises, and what a regulator asks for.

### How the sandbox stands in for this

There is no provider table here. Building one would mean modelling your system
inside a sandbox meant to demonstrate an integration, and it would go stale the
first time `org-setup-service` changed. Instead the token carries the claims:

```bash
# A clinician
scripts/mint-token.sh --user 7 --provider-id 4412 --license ML-4412
# An account with no provider row
scripts/mint-token.sh --user 8 --name front.desk --no-provider
```

`mint-token.sh` defaults the provider id to `9000 + usr_id` so the two are never
the same number in an example — the whole point is that they are different
things, and a default that made them look alike would teach the wrong lesson.

**Your version replaces the claim with a lookup**, resolving `usr_id` to the
provider row at the point the order is created. Everything downstream of that —
`db/his/015_provider_identity.sql`, the bridge's `buildOrderingClinician` in
`order.mapper.ts` — is the same either way.

One sandbox artefact **not** to copy: the licence is stored on the order row
here. A licence belongs to a practitioner, not to an order, and in your HIS it
should be joined from the provider row at dispatch. It is on the order here only
because there is nothing to join to.

Three things are deliberately **not** sent to the laboratory at all: the file
number / MRN, the requesting organisation, and the visit number. They are yours,
and the reasoning for each is in
[integration-contract.md §5](integration-contract.md#5-what-is-deliberately-not-sent).

> **`OE_REMOTE_SOURCE_IDENTIFIER` must be typed `Organization/…`, not
> `Practitioner/…`.** It is the address OpenELIS polls on, and OpenELIS also
> treats a Practitioner-typed owner as the answer to "who ordered this" — which
> hides the real clinician behind the integration's own identity. Getting the
> *value* wrong is worse than getting the type wrong: no order reaches the
> laboratory at all, and every order already published under the old value is
> stranded. Drain the queue before you change it.

### Naming the laboratory

A laboratory is normally a **department inside a hospital**, not a separate
business, so it is called after the hospital: "Stanford Lab", not a product name.
Two values, and they are meant to agree:

| | Set where | Source in the estate |
|---|---|---|
| `OE_LAB_NAME` | `.env` — our copy | `mlh_org_stup_healthcare_organization.organization_name` |
| the `organization` row | OpenELIS → *Administration → Organization Management* | the same |

The OpenELIS row is the **authoritative** one: it is what the laboratory's own
screens and reports read, and `OE_REMOTE_SOURCE_IDENTIFIER` is that row's
`fhir_uuid`. Ours is a copy carried on the orders we publish. Nothing enforces
that they match, because the laboratory owns its own records — but two names for
one laboratory is the drift this integration exists to prevent.

### Names go in Latin script, and carry no digits

OpenELIS validates every name it stores against a per-site character set. On this
stack, read live from `/rest/configuration-properties`:

```
FIRST_NAME_REGEX   ^[.'a-zàâçéèêëîïôûùüÿñæœ -]*$
LAST_NAME_REGEX    ^[.'a-zàâçéèêëîïôûùüÿñæœ -]*$
```

Konaté, N'Diaye and Diallo-Sow all pass. A digit does not, and a name in another
script does not.

> **If you copy that regex, copy the flags too.** The character class is
> lowercase-only, and OpenELIS compiles it as `new RegExp(pattern, "iu")`.
> Applied without the `i`, it rejects every properly capitalised name — a
> validator that refuses "Konaté" and accepts "konaté" is worse than none.
> Better still: fetch the patterns at runtime rather than hardcoding a copy,
> since the laboratory can change its own charset.

This bites harder than a rejection. A name the laboratory refuses makes the
import throw; a failed import never acknowledges the Task, so its status stays
`requested` and the next poll picks it up again, indefinitely. We hit this with a
patient called `Probe233437`, and one of the retries created a duplicate patient
record. **Validate names at your own edge**, where you can tell the user.

Note the asymmetry that catches people: this applies to **names**, not to
identifiers. `patientIdCharset` allows digits — a national id of `NID-000001` is
fine on the same patient whose name must not contain a `2`.

## Step 6 — Receive results

```
GET /patients/{id}/results
GET /visits/{visitNumber}/results
GET /lab-orders/{orderId}          → { order, results }
```

The first two return a bare array, newest first, and `[]` — not a 404 — for an
unknown patient or visit. All three share one projection, so the result shape is
identical across them. Fields are listed in
[integration-contract.md §3](integration-contract.md); what follows is what to
*do* with them.

**Neither the patient nor the visit is read back from what the laboratory
returns.** Both are joined from the order row that `orderNumber` identifies.
That is what makes filing correct even when results arrive out of order, or when
a correction lands weeks after the encounter closed.

**Show `labAccession` next to `orderNumber`.** They are the two numbers a person
quotes, and they are quoted to different people: `orderNumber` identifies the
order in *your* system, `labAccession` identifies it in the *laboratory's*. When
a ward telephones the lab about a result, only the second one can be looked up by
whoever answers. It is null until a lab user accessions the sample.

**`specimenType` is not decoration.** Two orders for the same LOINC on different
specimens share a `testName` — "HIV VIRAL LOAD" for both plasma and dried blood
spot — and are different examinations with different methods and reference
ranges. Show it, or your clinicians cannot tell the two apart.

The MRN is not carried and does not need to be — resolve it from `patientId`,
which you own.

**Results can be corrected after release.** Treat `resultStatus` as a state, keep
the history, and never overwrite a previous value in place — see
[Step 6c](#step-6c--corrections-need-an-alert-not-a-badge).

### Step 6a — Read `components`, or you will lose a panel

**`resultValue` is one analyte. `components` is the report.**

For every test on this sandbox's menu they say the same thing, because every one
of those tests measures a single analyte. The day your laboratory offers a full
blood count that stops being true: the report carries eight analytes,
`resultValue` holds the first, and a HIS that files it into the patient record
has filed one eighth of a blood count with nothing indicating the rest existed.

So:

- **File `components`.** One row per analyte, ordered by `position`, each with its
  own value, unit, reference range and interpretation.
- **Treat the flat fields as a summary**, not as the result. They are kept
  populated on purpose so nothing that already reads them breaks, and they are
  the first component — useful for a list view, wrong as the record.
- **Key severity per component.** `interpretationCode` on a component is that
  analyte's. A panel that is normal in six analytes and `HH` in the seventh must
  show the seventh as critical; a report-level severity cannot express it.
- **Expect the set to be replaced on a correction**, and to be **empty on a
  retraction**. Do not merge component-by-component — a corrected report is a new
  statement about every analyte in it, and merging leaves a withdrawn analyte on
  screen. The sandbox deletes and re-inserts the whole set for exactly this
  reason.

`components` is always present and always an array. Empty means the laboratory
withdrew the report; one element is the ordinary case; more than one is a panel.

### Step 6b — Collection time is a separate fact from release time

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

### Step 6c — Corrections need an alert, not a badge

**This is the one place where doing what the sandbox does is not enough.**

A laboratory does not only publish results — it corrects and withdraws them, and
the evidence on what happens next is unusually clear:

- a chart review of 480 corrected microbiology reports found **6.7% caused
  measurable adverse clinical impact** — delayed therapy, unnecessary therapy,
  inappropriate therapy, or an increased level of care
- an AHRQ patient-safety review puts roughly **30% of amended values as changing
  patient care**, and names the mechanism directly: *"clinicians are not
  anticipating a change in information"*
- a study of amended surgical pathology reports found the same failure again, and
  located it precisely: the correction existed in the LIS and **did not reach the
  treating clinician**

Note where that failure sits. Not in the laboratory, which did its job. Not in
the interface, which delivered the message. In the **last hop** — getting a doctor
who has already moved on to look again.

#### What the integration guarantees you

The bridge publishes every correction as its own `lab.result.released` event with
`resultStatus` set to `corrected` or `amended`, deduplicated on
`(openelisResultRef, meta.versionId)` so a genuine new version is never
suppressed while a redelivery is. Corrections arrive as distinct, ordered,
at-least-once events. **You will be told.**

The sandbox frontend then shows the new value, a `corrected` badge, and the
superseded value beneath it (`previousValue`). That satisfies ISO 15189 7.4.1.8 —
a revised report must reference what it revised — and it is where a demonstration
stops.

#### What your HIS must add

A badge only works on a clinician who happens to be looking at the screen. The
studies above describe clinicians who are not. So the correction has to **go find
them**:

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
   anything it is louder. It arrives with every value nulled and
   `components: []` — the retraction *is* the message.
5. **Alert on the critical tier separately.** `interpretationCode` carries the
   HL7 code, where `AA` / `HH` / `LL` mean *critically* abnormal rather than
   merely abnormal. Never key this off the display wording — `interpretation`
   holds the laboratory's own text and it is free to change; a severity rule that
   matches on the word "critical" fails silently the day it becomes "panic".
   CLIA 42 CFR 493.1109(f) and ISO 15189 7.4.1.3 both oblige the laboratory to
   telephone a critical value; a HIS that renders it with the same visual weight
   as a routine result defeats a notification the laboratory is legally obliged
   to make.

#### What not to do

**Do not suppress the old value.** A clinician who acted on 13.8 needs to see
13.8 to judge whether that decision still stands. ISO 15189 7.4.1.8 requires the
revised report to identify the original; the operational guidance is explicit
that previous results and interpretations are replicated *precisely because
decisions may have been based on them*. Showing only the corrected number is the
pattern the literature associates with missed-correction harm.

**Do not treat a new resource id as the signal.** FHIR corrections update the
*same* Observation with a new `status` and an incremented `meta.versionId`. A HIS
watching for new ids will not see corrections at all.

## Step 7 — Handle the unhappy paths

An order moves through seven statuses. Your HIS must react to more than the happy
one.

| status | meaning | what to do |
|---|---|---|
| `CREATED` | accepted, queued for dispatch | nothing — it is in flight |
| `AWAITING_COLLECTION` | **the laboratory has heard nothing** — an inpatient order waiting on a bedside draw | not a fault: put it on the ward's worklist. Nothing will move it but a nurse |
| `SENT_TO_LIS` | published, not yet acknowledged | nothing yet; see the timeout note below |
| `ACCEPTED_BY_LIS` | the laboratory has it | refine with `labProgress` |
| `REJECTED_BY_LIS` | the laboratory refused the order | show the doctor the reason; it is in `statusDetail` |
| `FAILED` | the bridge refused to send it | usually a stale catalogue — re-sync, re-order |
| `RESULT_AVAILABLE` | a released result is stored | file it |

`labProgress` is a **second axis, not a status**: `IN_LABORATORY` then
`AWAITING_VALIDATION`, both underneath `ACCEPTED_BY_LIS`. It only ever advances,
and it never contradicts the status.

`AWAITING_COLLECTION` is the one that looks like a stall and is not. Every other
waiting state means a system has the order and has not finished with it; this one
means **nothing has been sent** — no event, no Task — because the specimen does
not exist yet. Triage it as a ward question, never as an integration incident.

There is deliberately no timeout on it. Expiring a real pending order because a
nurse was busy would be worse than leaving it visible, so **build an escalation
on top of that queue** rather than expecting the sandbox to clear it.

**Known ambiguity, and you should design around it:** OpenELIS reports `rejected`
both when the laboratory genuinely declines a test **and** when it hits an
internal storage error. They are indistinguishable from outside. Do not tell a
clinician "the laboratory refused this" with certainty — say the order did not
complete and needs review. Filed upstream as
[defect 01](upstream-issues/01-task-poll-not-idempotent.md).

### How long is "too long"

Worth knowing what the cadence actually is before you set a threshold. OpenELIS
polls on a Spring schedule whose default is read straight from the deployed
bytecode:

```java
@Scheduled(fixedRateString = "${org.openelisglobal.remote.poll.frequency:120000}")
@Async
public void pollForRemoteTasks()
```

**Two minutes**, and the property is commented out in `application.properties`,
so the default is what runs. Measured on this stack at idle: five mutually
authenticated FHIR requests per minute.

Two details in that annotation matter. `fixedRate`, not `fixedDelay`, means the
next poll starts on schedule whether or not the previous one finished — combined
with `@Async`, polls can overlap, which is the mechanism behind defect 01. And an
order whose import throws is never acknowledged, so it stays `requested` and is
picked up again on the next cycle, for ever. That is the retry loop; nothing
gives up on its own.

## Step 8 — Match the infrastructure contracts

The bridge already speaks these; your services should too.

- **Health** — `GET /health` returning the same document shape, so one probe works
  everywhere
- **Consul** — register with the same naming and health-check convention
- **Metrics** — `/metrics` in Prometheus format, same metric names
- **Logs** — structured JSON, and **propagate the correlation id**: it is what
  lets you follow one order across the HIS, Kafka, the bridge and OpenELIS

Send `X-Correlation-ID` on every request. his-api honours it, echoes it on the
response, and puts it on the Kafka header of the resulting event; the bridge
carries it onward. The correlation id is the single most useful thing here.

## Step 9 — Prove it

Run the suites against your stack. They are the specification in executable form:

```
make unit             the bridge's pure functions — no stack needed
make smoke            platform and wiring
make catalogue-test   the menu, and the specimen abbreviations
make e2e              a real order into OpenELIS  (pauses for the lab step)
make collection       the outpatient and inpatient workflows
make requester        the ordering clinician, end to end
make results          the return path
make panel            a report with several analytes
make progress         where an order has got to inside the laboratory
make corrections      corrections and retractions
make rejection        refusal and drift
make negative         outages: broker, Redis, API, OpenELIS
make auth             tokens, revocation, degraded mode, audit
make monitoring       the gauges and whether the alerts can fire
make patient-refresh  a known upstream limitation, held under test
```

If `catalogue-test` fails, stop. A catalogue problem produces **silently wrong
test binding**, which is worse than an outage because nothing looks broken.

If `panel` fails, stop before offering any multi-analyte test. The failure mode is
a report arriving with one number where the laboratory released eight, and
nothing anywhere says so.

`patient-refresh` is the odd one: it **passes** by confirming that a corrected
patient name does *not* reach the laboratory. It is a tripwire on
[upstream issue 07](upstream-issues/07-patient-name-never-refreshed.md), written
to go red when a future OpenELIS release fixes the freeze. If it fails on your
stack, read it as good news and check whether the workaround is still needed.

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

**Wake someone.** Half of this is now done: a Prometheus container scrapes the
bridge, his-api and Kong, and seven rules in
[`monitoring/alerts.yml`](../monitoring/alerts.yml) cover the quiet failures —
orders stuck undelivered, dead letters growing, the catalogue sync ageing or
never having run, and OpenELIS not polling — plus service-down and the result
consumer. `make alerts` shows what is firing and `make reconcile` gives the daily
ledger.

**What is missing is the routing.** There is no Alertmanager, so nothing pages
anybody: an alert fires and waits for someone to look. That last step is
deliberately left to you, because who is on call and how they are reached is your
decision, and a sandbox that shipped one arbitrary answer would teach it as though
it were the answer. Point Alertmanager at these rules and you are done.

Two things learned building it, worth carrying over. **A gauge that has never
refreshed must be absent, not zero.** Every Prometheus client registers a gauge at
`0` the moment you construct it, and a broken refresh loop then publishes
"nothing stuck, no dead letters, catalogue fresh" while never once querying the
database. The bridge defeats that by not constructing the gauges until a refresh
has actually returned numbers — `gauges ??= createGauges()`, so the four
integration gauges are genuinely missing from `/metrics` until the collector has
worked at least once. And **a rule can be `health: ok` and incapable of firing**,
because Prometheus validates that an expression parses, not that the metric
exists; rename a gauge and its alerts go silent for ever behind a green rules
page. `make monitoring` guards both.

**Use real certificates.** The mTLS between bridge and OpenELIS uses a CA we
generate. That is genuine mutual authentication and worth keeping, but the
material needs to come from your PKI with a documented rotation procedure —
including the fact that OpenELIS reads its truststore **once at startup**, so
rotation means a restart.

**Decide the unacknowledged-order policy.** There is deliberately no timeout on an
order OpenELIS never acknowledges. The bridge counts delivery attempts, so the
condition is *visible*, but nobody is told. Decide how long is too long and who
gets called — [Step 7](#how-long-is-too-long) has the cadence to base it on.

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
