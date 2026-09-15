# Findings and recommendations — the real HIS

Everything the OpenELIS sandbox turned up that applies to **your** codebase
rather than to the sandbox, in one place.

None of it came from reading documentation. Each item was found either by
reading `HIS Project` source directly, or by hitting the same problem while
building the sandbox against your stack — and where the sandbox fixes something,
there is working code to copy, not a snippet.

**How to read this.** Part 1 is defects: things that are wrong now. Part 2 is a
design for something you do not have yet and will be asked for. Part 2b is what
an outside laboratory will ask of `org-setup-service` — two places where the
natural choice is the wrong one. Part 3 is what the sandbox took *from* you, and
Part 4 is what the laboratory imposes on you whatever you do.

> **Re-verified against `HIS Project` on 2026-09-15.** All ten defects below
> still exist, and every code snippet quoted was re-read from the current
> source rather than carried forward. Line numbers are as they stand today —
> nine of the ten were unchanged; the two in `config/kafka.ts` had moved and are
> corrected. One new instance of finding 6 was found and is recorded there.

---

## Summary

| # | Finding | Where | Consequence | Effort |
|---|---|---|---|---|
| 1 | No transactional outbox | `patient-service` visits module | An order exists and billing never hears about it | Design change |
| 2 | Dead-letter queue is unreachable | `order-fulfillment.consumer.ts:24` | A poison message blocks its partition for ever | **One line** |
| 3 | Failed publish looks successful | `config/kafka.ts:142` — every service | Callers cannot retry what they cannot see fail | Small |
| 4 | Producer not idempotent | `config/kafka.ts:126` — every service | A retry can overwrite a newer status with an older one | **Two lines** |
| 5 | `jwt.decode` instead of `jwt.verify` | `org-setup-service`, `file-upload-service` | Signature unchecked, expiry ignored | **One word, twice** |
| 6 | Hardcoded fallback signing secret, **twice** | `file-auth.middleware.ts:8`, `signed-url.utils.ts:9` | Unset variable ⇒ links signed with a public string | **Two lines** |
| 7 | Degraded mode does not degrade | `config/redis.ts` — every service | A Redis outage hangs requests instead of bypassing the check | **One line** |
| 8 | Outage logs once per request | `auth.middleware.ts` | Thousands of identical lines/min on the shared topic | Small |
| 9 | Consul registration takes `eth0` | `config/consul.ts:22` | Breaks the moment a service joins a second network | Small |
| 10 | HS256 with no `aud` | `iam-service` | Every verifier can mint; nothing scopes a token to one service | Design change |

Items 5, 6 and 7 interact and are the ones to take first — see **Sequencing** at
the end.

**Two more things your HIS must handle**, found while testing against a real
OpenELIS. Neither is a defect in your code, and both will cost you real orders if
nobody knows about them:

| Finding | Consequence | Effort |
|---|---|---|
| **Patient names must not contain digits** — the laboratory's `lastNameCharset` excludes them | An order for a patient called `Doe 2` stays `SENT_TO_LIS` for ever: no rejection, no dead letter, nothing to look at | Small — validate at registration |
| **A corrected patient name never reaches the laboratory** | The two systems permanently disagree about whose specimen is on the bench | Cannot be fixed in code — needs a workflow |

Both are covered in **Part 4** below.

---

# Part 1 — Defects

## Messaging

### 1. Orders can be silently lost — no transactional outbox

**Where:** `modules/visits/services/clinical-order.service.ts` →
`modules/visits/events/order-fulfillment.producer.ts`

A clinical order is committed to Postgres, and *then* the event is published as
a separate step:

```ts
await kafkaProducer.send(ORDER_FULFILLMENT_TOPICS.ORDER_CREATED, String(visitId), event);
```

If the broker is unreachable, or the pod is killed between the commit and the
send, **the order exists and billing never hears about it.** Nothing errors,
nothing retries, and there is no record that anything was missed. The only way
to find these is to reconcile `clinical_order` against billing's fulfilments
and look for gaps.

This compounds with #3 below, which is what makes it silent rather than merely
possible.

**Fix — transactional outbox.** Write the event to an `outbox` table *in the
same transaction* as the order. A relay polls the table and publishes, deleting
only after the broker acknowledges. The commit becomes atomic: either the order
and its event both exist, or neither does.

```sql
BEGIN;
  INSERT INTO clinical_order (...);
  INSERT INTO outbox (topic, key, payload) VALUES (...);
COMMIT;
```

The relay claims rows with `FOR UPDATE SKIP LOCKED` so several instances can
drain it concurrently without publishing the same event twice, and stops at the
first failure so per-aggregate ordering holds.

The sandbox implements this end to end — `services/his-api/src/modules/messaging/outbox.relay.ts` and
`db/his/002_outbox.sql` — and `make negative` proves it by stopping the broker
mid-flight: orders are still accepted, the event is queued durably, nothing is
marked failed, and the relay drains it unattended when Kafka returns.

---

### 2. The dead-letter queue is unreachable

**Where:** `modules/visits/events/order-fulfillment.consumer.ts:24` and
`config/kafka.ts:84`

```ts
// order-fulfillment.consumer.ts
async handleMessage(topic: string, message: any, retryCount = 0): Promise<void> {
  try { ... }
  catch (error) {
    if (retryCount >= 3) {
      await publishToDLQ(topic, message, error as Error, retryCount);
    } else {
      throw error;                       // let KafkaJS retry
    }
  }
}
```

```ts
// config/kafka.ts — the only caller, and it passes two arguments
await orderFulfillmentConsumer.handleMessage(topic, data);
```

`retryCount` is therefore **always `0`**. `retryCount >= 3` is never true, so
the code always re-throws and `publishToDLQ` is dead code.

KafkaJS retries the batch, calls `handleMessage` again with `0`, and the cycle
repeats. A message that can never succeed — a schema change, a null where one
isn't expected — **blocks its partition indefinitely**, and every fulfilment
update behind it stops arriving. `billing.orders.dlq` stays empty while the
problem it exists for is happening.

**Fix.** Track attempts outside the call, since KafkaJS does not thread them
through. Either read `message.headers` for an attempt counter you set, or keep
a short-lived Redis counter keyed on the message's `idempotency_key` — you are
already using Redis for idempotency in the same class:

```ts
const key = `dlq-attempts:${message.idempotency_key}`;
const attempts = await redis.incr(key);
await redis.expire(key, 3600);

try { ... }
catch (error) {
  if (attempts >= 3) {
    await publishToDLQ(topic, message, error as Error, attempts);
    return;                              // commit past it
  }
  throw error;
}
```

**Also worth knowing:** `publishToDLQ` calls `kafkaProducer.send`, which
swallows its own errors (#3). So even once this path is reachable, a failed DLQ
publish is invisible. Fixing #3 fixes that too.

---

### 3. A failed publish looks exactly like a successful one

**Where:** `config/kafka.ts:142` — `KafkaProducer.send()`

```ts
public async send(topic: string, key: string, value: any): Promise<void> {
  if (!this.connected) throw new Error('Kafka producer not connected');
  try {
    await this.producer.send({ topic, messages: [{ key, value: JSON.stringify(value) }] });
  } catch (error) {
    console.error('Failed to send Kafka message:', error);   // ← returns normally
  }
}
```

The promise resolves whether or not the message was published. Callers cannot
tell, so no caller can retry, compensate, or refuse to commit.

Note also that it is `console.error`, not `logger.error`. The one record that an
event was lost goes to the container's stdout and **never reaches the shared
`logs` topic**, so it is absent from the place anyone would search afterwards.

`publishOrderCreatedEvent` then catches again on top:

```ts
} catch (error) {
  logger.error('Failed to publish order-created event to Kafka', { visitId, error });
  // Don't throw, fire-and-forget
}
```

Two layers, same effect. This is why #1 is silent: the publish can fail
completely and the request still returns 201.

**Fix.** Let `send` reject. Fire-and-forget is a decision for the *caller* to
make explicitly, per call site, not a property baked into the transport — some
events genuinely are best-effort (logs), and some are an order for a patient.

This affects **every service** using `config/kafka.ts`, not just
patient-service.

---

### 4. Producer is not idempotent, so retries can reorder

**Where:** `config/kafka.ts:126` — `this.producer = this.kafka.producer();`

No options. KafkaJS defaults give `acks: -1` (all in-sync replicas), which is
right — but `idempotent: false` and unbounded in-flight requests, which means a
retried message can land *after* one produced later. For fulfilment status
transitions on the same order, that means an older status can overwrite a newer
one.

**Fix:**

```ts
this.producer = this.kafka.producer({
  idempotent: true,        // sets acks=-1, maxInFlightRequests=5, retries=Infinity
  maxInFlightRequests: 5,
});
```

#### Related: the idempotency key changes on retry

```ts
const idempotencyKey = `order-created-${visitId}-${firstOrder.id}-${timestamp}`;
```

`timestamp` is `Date.now()`, so retrying the same logical operation produces a
*different* key and the consumer treats it as a new event. The key protects
against redelivery of the same message, not against the same operation being
attempted twice.

Derive it from the data instead — `order-created-${visitId}-${firstOrder.id}` is
already unique per order, and stable across retries.

---

### Infrastructure notes

Not defects, but worth a decision:

| | Current | Note |
|---|---|---|
| Broker image | `apache/kafka:latest` | Unpinned — a rebuild can change your broker version with no commit. Pin it. |
| Replication | RF 1, single broker | A broker failure loses messages regardless of `acks`. Needs 3 brokers with `min.insync.replicas=2`. |
| `min.insync.replicas` | not set | Without it, `acks=-1` can mean "the one replica that was up". |
| Auto-create topics | enabled | A typo in a topic name silently creates a topic nobody consumes. |

### Two event shapes are in circulation

`billing.visit.create-requested` carries a full envelope — `event_id`,
`event_type`, `event_version`, `occurred_at`, `source`, `key`, `data` — and
`config/kafka.ts` has a compatibility branch that upgrades the old flat format
to it.

The order path does not use that envelope. Since the newer shape has
`event_version` in it, adopting it consistently is what makes the *next* schema
change survivable.

---

## Authentication and sessions

### 5. Two services verify nothing

| Service | Line | What it does |
|---|---|---|
| `HIS-org-setup-service` | `src/middleware/auth.middleware.ts:31` | `jwt.decode(token)` |
| `file-upload-service` | `src/middleware/auth.middleware.ts:32` | `jwt.decode(token)` |

**`jwt.decode` does not verify the signature and does not check expiry.** It
base64-decodes the payload and hands it back. `patient-service` was fixed — the
comment there still reads *"CRITICAL SECURITY FIX: verify the signature, do not
just decode it"* — but these two were not.

What saves them **today** is the Redis lookup two lines later: a forged token
for `usr_id: 1` is compared against the real session for user 1 and does not
match, so the request is refused. That is an accident of ordering, not a
control. It fails the moment either service adds the degraded-mode fallback
`patient-service` already has — at which point a token anyone can write, for any
user, is accepted whenever Redis blinks.

**Expiry is already broken there regardless.** `decode` ignores `exp`, so an
expired token keeps working until the 24-hour session hash expires, however
short `JWT_EXPIRE` is set.

```ts
// one word, in each file
const decoded = jwt.verify(token, process.env.JWT_SECRET!, { algorithms: ['HS256'] });
```

Pinning `algorithms` is the second half. Without it the library accepts any
algorithm the key can verify — for a string secret that is the HMAC family only,
so it is not the classic confusion hole, but it costs one line and removes the
question for whoever later changes the key type.

### 6. A signing secret with a public fallback

```ts
// file-upload-service/src/middleware/file-auth.middleware.ts:8
const secret = process.env.SIGNING_JWT_SECRET || 'your-secret-key';

// file-upload-service/src/utils/signed-url.utils.ts:9   ← same string, different variable
const secret = process.env.JWT_SECRET || 'your-secret-key';
```

**There are two of them**, and they do not even read the same variable: the
middleware falls back for `SIGNING_JWT_SECRET`, the URL builder for
`JWT_SECRET`. So a deployment that sets one and not the other signs with the
public string at one end and the real secret at the other — which fails closed
by accident, until someone "fixes" the mismatch by setting neither.

If either variable is unset — a new environment, a renamed key, a typo — file
download links are signed and verified with a string that is in the repository.
Anyone can then mint a link to any file.

**Fail closed instead.** No fallback; refuse to start, or answer 503. An unset
credential must never be the thing that opens a door. The sandbox does this in
`services/his-api/src/core/middleware/admin.middleware.ts`.

### 10. HS256, and no `aud`

Two properties follow from a shared symmetric secret, and neither can be fixed
in a consuming service:

- **Every verifier is also an issuer.** The key that checks a signature makes
  one. Any service holding `JWT_SECRET` — and they all do, because they all
  verify — can mint a token for any user with any groups.
- **Nothing scopes a token to one service.** IAM's payload has no `aud`, so a
  token minted for the appointment service is equally valid at the laboratory
  API.

**The fix is in IAM, and only in IAM.** Sign RS256: IAM holds the private key,
every other service gets the public one via JWKS and can only verify. Add `aud`
and have each service require its own. Neither change breaks a consumer that
ignores those fields today, so it can be rolled out ahead of the consumers.

### Sessions are one-per-user, and live only in memory

Not defects — consequences worth knowing, because users will report them as
bugs:

- `storeUserTokenAndPermissionsInRedis` writes a single `token` field per user,
  so **signing in on a second device ends the first session**.
- Redis runs without persistence, so **restarting it signs out every user in the
  hospital**. Tokens stay validly signed, but no session exists to match them
  against. If that is not acceptable, `appendonly yes` on the session instance
  costs almost nothing — the data is small.

---

## Resilience

### 7. Degraded mode does not degrade

**Where:** `config/redis.ts` — every service

```ts
const redis = new Redis({ host: process.env.REDIS_URL || 'localhost', port: ... });
```

`patient-service`'s auth middleware is written to survive a Redis outage: it
catches, logs, and continues without the revocation check. **That fallback is
unreachable.**

ioredis defaults to `enableOfflineQueue: true`, which *queues* commands issued
while the connection is down and replays them on reconnect. The `HGET` never
errors — it simply does not finish. So instead of failing fast and continuing,
every request waits for Redis to come back. The catch block never runs.

```ts
enableOfflineQueue: false,   // the fix
commandTimeout: 250,
maxRetriesPerRequest: 1,
```

With the queue off, a command issued while disconnected rejects in microseconds
and the degraded path actually runs. The sandbox asserts this: with Redis
stopped, the clinical API must answer **in under five seconds**. That assertion
fails on the current settings.

See `services/his-api/src/config/redis.ts`, and `make auth`.

**Related, same file:** `host: process.env.REDIS_URL` treats `REDIS_URL` as a
*hostname*. A value like `redis:6379` or `redis://redis:6379` — both of which
look right in a compose file — is resolved as a host, never connects, and leaves
the service permanently in degraded mode with nothing announcing it.

### 8. An outage logs once per request

**Where:** `patient-service/src/core/middleware/auth.middleware.ts:62`

The degraded-mode warning is inside the per-request catch block. An outage is
precisely when request volume does **not** fall, so at any real rate that is
thousands of identical lines a minute — on a Kafka topic shared with every
service in the estate.

Log the **transition**, not the state: one line when Redis goes, one when it
returns. Then add a metric for the thing you actually want to alert on:

```
auth_revocation_checks_total{result="allowed"|"revoked"|"degraded"}
```

`degraded` above zero means logouts are not taking effect. That is the alert.
Without it, degraded mode is invisible — the requests all succeed, so no error
rate moves.

The same lesson bit the sandbox from the other direction. The bridge was an
ASP.NET service at the time, and its four Information lines per request, plus a
10-second Consul check, put **~2,800 messages in five minutes** on the shared
topic from an idle service. Filtering framework categories to Warning and above
took it to 21. (The bridge is Node now, and Express logs nothing per request —
so the rule there is simply never to add a request logger.)

---

## Platform

### 9. Consul registration takes `eth0`

**Where:** `config/consul.ts`

Correct today, and only because every service sits on exactly one network. The
moment any service joins a second one — an integration network, a data network,
a service mesh — `eth0` becomes a coin flip, and the wrong choice is worse than
not registering at all: the service appears healthy in the catalogue and Kong
routes to an address Consul cannot reach.

The sandbox hit exactly this. The bridge sits on three networks; it registered
its `oe-data-net` address while Consul watched `oe-sandbox-net`, and every
health check failed.

The question is not *"what is my address"* but *"what is my address **from the
registry's side**"*, and only the routing table can answer it. Connecting a UDP
socket sends no packets — it asks the kernel which local address it would use:

```ts
const probe = dgram.createSocket('udp4');
probe.connect(consulPort, consulHost, () => {
  const { address } = probe.address();   // the address Consul would see
  probe.close();
});
```

### A boundary made of network membership is not a boundary

Found while enabling mutual TLS, and the most transferable item here.

Docker resolves a plain container name to its address on **one** of the networks
the two containers share — and which one is not something you chose. The sandbox
put OpenELIS and the bridge on a dedicated `integration` network and believed
that was the only path between them. It was not: DNS was answering with the
**data** network address, so the traffic had been crossing that instead.
Membership was true; the packets did not follow it.

**A network alias fixes it, because the name itself pins the route.** The
bridge's `bridge.openelis.org` alias exists only on `integration`, so a caller
using that name cannot reach it any other way.

Worth checking wherever you have declared a network to be a boundary.

---

# Part 2 — To build: an audit trail

You will be asked for this by anyone assessing the system against IHE ATNA, ISO
15189, or a national health-data authority. It does not exist yet, and it is
easy to believe it does — because there *are* audit rows and there *are*
structured logs. Neither is what is meant.

## What is actually missing

| What you have | What it answers |
|---|---|
| `mlh_*` audit columns, order state rows | *what happened to this record* |
| Winston logs on the `logs` topic | *what the software did* |
| — | **who read this patient's data, when, from where, and did it succeed** |

The third is the audit trail. It is a security record, not a clinical one, and
it is kept for different reasons, for a different length of time, under
different rules.

**Prerequisite: finding 5 first.** You cannot audit an identity you never
verified. An audit line naming `usr_id: 7`, produced by a service that called
`jwt.decode`, records whatever the caller typed. Audit built on those two
services today would be *worse* than none, because it would be believed.

## What to record

One event per access to patient data, and per access decision:

| Event | Why it matters |
|---|---|
| Token accepted | the baseline "who was here" |
| Token **rejected** — bad signature, expired, revoked | failed attempts are what an investigation starts from |
| Patient read or searched | the core question |
| Order created | ties the clinician on the token to the order |
| Result read, or received from the laboratory | patient data crossing a boundary |
| Anything administrative | already logged; this makes it a record |

**And what never to record: the data itself.** The trail records *that* a record
was read, never its contents. Otherwise it becomes a second copy of the patient
database, kept longer and guarded less.

## The shape

FHIR `AuditEvent` (R4) is the modern spelling of RFC 3881 / DICOM Supplement 95,
and you are already a FHIR estate, so it costs no new vocabulary:

```jsonc
{
  "resourceType": "AuditEvent",
  "type":    { "system": "http://terminology.hl7.org/CodeSystem/audit-event-type", "code": "rest" },
  "action":  "R",                          // C reate, R ead, U pdate, D elete, E xecute
  "recorded": "2026-08-23T09:14:22Z",
  "outcome": "0",                          // 0 success, 4 minor failure, 8 serious
  "agent": [{
    "who":       { "identifier": { "value": "7" } },   // usr_id
    "altId":     "dr.reed",
    "requestor": true,
    "network":   { "address": "10.2.0.44", "type": "2" }
  }],
  "source": { "observer": { "display": "patient-service" } },
  "entity": [{
    "what": { "reference": "Patient/3a4054ba-..." },
    "type": { "code": "1" }, "role": { "code": "1" }
  }]
}
```

## The design decision that matters

**An audit trail must not be droppable.** Your log shipper drops messages when
its buffer fills — correctly, so an observability problem cannot become an
outage. Audit is the opposite: an access that was not recorded must not have
happened.

Taken naively that means "fail the request if audit fails", which sounds like it
trades availability for compliance. **It does not, if you put the audit row in
the database the request already depends on:**

```sql
BEGIN;
  INSERT INTO lab_orders (...);
  INSERT INTO audit_events (...);        -- same transaction
COMMIT;
```

Anything that stops the audit write already stops the request. There is no new
failure mode, and no new decision to make. This is the outbox pattern again,
used for a second purpose — and for reads, the same argument holds: a read that
cannot reach the database cannot be served either.

Shipping to the central repository is then a **separate, asynchronous relay**
draining that table, exactly like `outbox.relay.ts`. It can lag; it cannot lose.

```
request ──► action + audit row, one transaction ──► [audit_events] ──► relay ──► ARR
```

## There is a working version to copy

Implemented in the sandbox rather than sketched, so the shape can be read rather
than imagined:

| | |
|---|---|
| `db/his/006_audit_events.sql` | the table, its indexes, and the append-only grants |
| `services/his-api/src/core/audit/audit.writer.ts` | three write paths: in-transaction, awaited, and best-effort for refusals |
| `services/his-api/src/core/audit/audit.middleware.ts` | per-route, so the entity comes from the route and the actor from the verified token |
| `make auth`, section 5 | eight assertions, including that the application cannot rewrite the trail |

**Append-only is enforced by the database, not agreed in a review.** The
application role is granted `SELECT, INSERT` and nothing else; the relay gets
`UPDATE (shipped_at)` — one column — so it can record that a row was shipped
without being able to change what the row says:

```sql
GRANT SELECT, INSERT ON his.audit_events TO his_app;
GRANT UPDATE (shipped_at) ON his.audit_events TO his_app;
```

That is a floor, not a ceiling: it stops the application, not a database
superuser. Real tamper-evidence needs the repository to be somewhere the audited
estate cannot write at all.

Two details worth copying exactly:

- **Refusals are recorded**, with `outcome = '4'`. An audit trail holding only
  the accesses that succeeded answers "who read this" but not "who tried".
- **Refusals are best-effort; everything else is not.** A caller being refused
  is being refused anyway — turning a 401 into a 500 because the audit write
  failed helps nobody. But that failure is logged loudly, because a trail
  silently not being written is how one is found empty months later.

## What still needs a decision from you

Four things the sandbox cannot decide, because they are policy:

1. **Where the repository lives.** A real ARR speaking syslog/TLS (RFC 5425), or
   Postgres plus a dedicated Kafka topic to begin with. Start with the second;
   the relay makes swapping it a configuration change.
2. **Who may read it.** The audit trail says which clinician opened which
   patient's record. That is sensitive in its own right, and it must not be
   readable by the people it monitors.
3. **Retention.** Years, not the days the operational tables use, and
   **append-only** — no `UPDATE`, no `DELETE`, revoked at the database role.
4. **Clock discipline.** Records from services whose clocks disagree cannot be
   ordered, and an audit trail that cannot be ordered is hard to rely on. NTP
   everywhere, and record `recorded` in UTC.

---

# Part 2b — What a laboratory integration will ask of org-setup

Not defects. Things the schema already has that an outside laboratory needs, and
the one place a natural choice is the wrong one.

## The ordering clinician is `hcp.id`, not `usr_id`

A laboratory has to name the ordering clinician on its own report — CLIA
42 CFR 493.1291(a), ISO 15189:2022 7.4.1.6.c — because the laboratory is who
telephones a critical value. So one of your two identities has to travel, and
`usr_id` is the tempting one because it is already on every request.

It is the wrong one, for reasons visible in your own schema:

```prisma
model mlh_his_hcp_health_care_provider {
  id             Int     @id @default(autoincrement())
  usr_id         Int?                                   // nullable, not unique
  license_number String?
  name, name_ar
}
```

- **`usr_id` is nullable.** A visiting consultant, a referring physician, anyone
  whose account was never created or has been disabled, is a provider with no
  login. Keyed on the account, those clinicians have no identity to send at all.
- **No unique constraint on it.** Two provider rows can share one.
- **`mlh_his_sys_patient_locations.ih_hcp_hcp_id` already identifies the
  attending doctor by `hcp.id`.** Sending the account would leave the
  laboratory's records unable to line up with your own.
- **An account is a session; a provider is a person.** Accounts get disabled,
  recreated and reassigned; the clinician who ordered a test in March is still
  that clinician in December. See the carry-through rule below — by the time a
  delayed order is published, the account may not exist any more.

The token still decides *who*: `verified token → usr_id → provider row →
hcp.id`. Nothing is read from a request body, so ordering on behalf of another
clinician stays impossible. Keep `usr_id` on the order for the audit trail —
"which account acted" and "which clinician is accountable" are different
questions and both get asked.

**Where the sandbox does it:** `db/his/015_provider_identity.sql`,
`OrderMapper.BuildOrderingClinician`, proved by `make requester` §2 and §6.

## The clinician is captured once and carried — never re-read at dispatch

**This is the one on this page most likely to be got wrong, and it cannot fail in
the sandbox, so nothing here will catch it for you.**

The sandbox has one screen: the doctor orders, and the order goes to Kafka in the
same request. Your HIS has a workflow between those two points — insurance
verification, fulfilment, approval. The order row is written when the doctor
decides. It is *published* only when all of that clears.

One publish, at the end. What goes on `lab.order.created` is the order that came
out of the workflow approved — not a doctor's keystroke, and not one event per
transition. The topic name reads as *"ready for the laboratory"*, which is worth
saying aloud because `created` suggests otherwise and someone will eventually
wire it to the create handler. An order awaiting insurance does not belong in a
laboratory's queue, and an expired one nobody approved must never arrive at all.

### The three cases, and why one rule covers all of them

The gap between "written" and "published" is not a fixed length, and not always
the same shape:

| | What happens | Gap | Who publishes |
|---|---|---|---|
| **A · Auto-approved** | patient insured for everything, approval is automatic | ~10 seconds | a background job, or the doctor's own request |
| **B · Approved by a person** | insurance checked and cleared by staff. **Same order row** — nothing is re-created | minutes to days | the approver |
| **C · Expired, re-created** | approval arrives after the order lapsed; a supervisor re-creates it | days | the supervisor |

**One rule handles all three, because it never asks how long it took or who
approved.** Decide the clinician once, at the doctor's moment; everything after
reads it. What differs between the cases is only *which* mistake is available:

| | Read from the order row | Read from the session |
|---|---|---|
| **A** | Dr Touré ✅ | Dr Touré ✅ — *or `undefined`, if it is a background job with no session* |
| **B** | Dr Touré ✅ | **the approver** ❌ |
| **C** | Dr Touré ✅ | **the supervisor** ❌ |

Case **A is why this is hard to catch**: reading the session gives the right
answer, so a developer testing an insured patient sees the doctor's name and
concludes the code is correct. It is not correct — it is coincidentally right,
and it stops being right for cases B and C.

Two shadings worth naming, because B and C are *different actions*:

- **B — approval must not write the clinician columns at all.** It updates a
  status. An `UPDATE ... SET ordering_provider_hcp_id = <approver>` is the bug in
  its most direct form; there is nothing to "carry" here because it is the same
  row.
- **C — re-creation copies them** from the order being replaced, along with a
  new order number. The supervisor names an *order*, never a clinician.

And a detail on A that helps rather than hurts: **an automatic approval usually
has no user session at all.** A background job has no `req.user`, so the wrong
line yields `undefined` and fails loudly instead of silently naming the wrong
person. If your auto-approval path runs outside a request context, it is
structurally unable to make this mistake — which is worth knowing when deciding
where to put the publish.

The rule:

> Once the order row exists, the ordering clinician is read **from the order
> row**. Never from the session of whoever advances the workflow.

### Which service this belongs to

Not necessarily the one that created the order. In this sandbox both jobs live in
`his-api`, because it is one service; in your estate they are likely two:

```
order creation service          ← identity ENTERS here, from the token, once
        │
        │  the order row, with the clinician on it
        ▼
fulfilment / approval service   ← THE RULE LIVES HERE
        │                         it has req.user in scope and does not need it
        │  publishes to lab.order.created
        ▼
bridge                          ← decides nothing; carries what the row says
        ▼
OpenELIS                        ← prints what it is given; has no opinion
```

**The rule belongs to whichever service publishes to Kafka.** That is the one
with an authenticated approver in scope, which is exactly why it is the one that
will reach for `req.user`. The creating service is not where this goes wrong —
there, the signed-in user genuinely *is* the doctor.

Neither the bridge nor OpenELIS needs any change for any of this. They are
downstream of the decision, and they believe what they are told.

### The failing line, and the correct one

The failing version is one reasonable-looking line in whichever service publishes:

```ts
// ❌ WRONG — req.user at dispatch is whoever advanced the workflow:
//    the nurse, the receptionist, the supervisor who approved the insurance
const clinician = req.user.hcp_id;

// ✅ RIGHT — read what the doctor's order already says
const order = await client.query(
  `SELECT ordering_provider, ordering_provider_hcp_id, ordering_provider_license
     FROM lab_orders WHERE order_id = $1`, [orderId]);
const clinician = order.rows[0].ordering_provider_hcp_id;
```

The word **request** in `req.user` is the trap. It means *"whoever is making this
HTTP call right now"* — and at dispatch that is a nurse or a receptionist, three
days after the doctor went home. Nobody is asked to prove anything at this point;
the code reads a name off a row, the way a pharmacist reads the prescriber off a
prescription rather than telephoning the surgery.

Three identities sit close together at that moment, and only one is the answer:

| | Holds | At dispatch |
|---|---|---|
| `lab_orders.ordering_provider_hcp_id` | the clinician who decided | ✅ **read this** |
| `lab_orders.ordering_provider_id` | that doctor's login account | audit trail only |
| `req.user.hcp_id` | whoever is signed in *now* | ❌ never |

Written **once**, at creation, from the doctor's verified token. Never written
again — not by the approval step, not by the re-creation, not by the publish.

**It will pass every test written against it.** For the insured patient the
doctor orders and the approval clears within minutes, frequently in the same
session, so the clinician on the published order looks right. The bug surfaces
only when the two are different people — the delayed, insurance-held, supervisor
re-created order. That order has already waited three days, is the least likely
to be inspected, and is the one where the laboratory most needs a real doctor to
telephone. A critical potassium gets phoned to the front desk.

The variability is what makes it dangerous. A workflow that always took three
days would have been noticed; one that is usually instant hides it.

| Step | Clinician on the order | Actor |
|---|---|---|
| Doctor places it | from the **verified token**, written once | the doctor |
| Insurance / fulfilment / approval | **read from the order row** | audit trail |
| Expiry and re-creation | **inherited from the order replaced** | supervisor, audit trail |
| Publish to Kafka | **read from the order row** | the relay — it has no user |

The actor of each step goes in the audit trail. It never goes on the order.

This does not conflict with taking identity from the token. A supervisor
re-creating an expired order is doing a clerical act on a clinical decision
someone else already made and recorded; they name an **order**, not a clinician,
and the clinician travels with it. What must never happen is a screen that lets
anyone *choose* a doctor's name.

**Write the test that can fail:** create as a doctor, advance and publish as a
*different* user, assert the published clinician is still the doctor. A
same-session test proves nothing here.

There is a working one to copy — `scripts/test-requester.sh` §8. It uses the
sandbox's inpatient path, which happens to have the same shape as your workflow:

| Sandbox §8 | Your HIS |
|---|---|
| doctor places an **inpatient** order | doctor places an order |
| held, **nothing published** | held for insurance, nothing published |
| a **nurse** records the bedside draw | a **supervisor** approves |
| *then* it dispatches | *then* it dispatches |

Two actors, two moments, publish at the end. Only the reason for the wait
differs — so no insurance phase had to be modelled to get the property under
test.

It was **mutation-tested**: the bug above was written into the dispatch
deliberately, and §8 went red. Which is the point — a rule stated in a document
is a rule that gets broken quietly, and a test that cannot fail reports safety it
has not established. That exercise also caught a flaw in the test itself: the
"…and NOT the nurse" check was passing vacuously when nothing was published at
all, and now requires a clinician to be present before checking which one it is.

### One order, start to finish

The rule stated as a story, because that is the form people remember.

**Monday 09:14 — Dr Touré orders.** He is signed in. His token says:

```json
{ "usr_id": 4021, "usr_full_name": "Ibrahim Toure",
  "hcp_id": 812, "hcp_license": "ML-812" }
```

He orders a potassium for Aminata Diallo. **This is the only moment anyone's
identity is checked.** The order row is written:

| Column | Value | |
|---|---|---|
| `ordering_provider` | Ibrahim Toure | printed on the report |
| `ordering_provider_id` | **4021** | his login — audit trail |
| `ordering_provider_hcp_id` | **812** | him, the clinician |
| `ordering_provider_license` | ML-812 | what the laboratory recognises |

Nothing goes to Kafka. It is waiting on insurance.

**Monday evening → Wednesday.** Dr Touré finishes his shift. Next morning he
signs in on the ward tablet, which **ends his Monday session**; by Tuesday night
that token had expired anyway. None of this matters. His name is on the order
like ink on paper.

**Wednesday 11:02 — approval lands.** Two ways it can go, and both end the same:

- *Case B* — the order is still live. Fatima at reception approves it. The status
  changes; **the clinician columns are not touched.**
- *Case C* — the order lapsed. Fatima re-creates it: a new order number, and
  `ordering_provider_hcp_id` **copied from the order it replaces**. The audit
  trail records *"re-created by Fatima Sow (usr_id 5570)"*.

Fatima's token has **no `hcp_id`** — she has an account, not a provider row. She
is not a clinician and never becomes one.

**Wednesday 11:02 — it dispatches.** The publishing code has two ID-shaped things
in front of it:

```ts
req.user.hcp_id                   // undefined — Fatima is not a clinician
order.ordering_provider_hcp_id    // 812 — Dr Touré
```

It reads the row. The laboratory is told: **Ibrahim Touré, hcp_id 812, ML-812**.

**Thursday 15:40 — why it mattered.** The potassium comes back at **6.8**.
Critical. The laboratory picks up the phone, and calls **Dr Touré**.

**The version that goes wrong** differs by one line at dispatch. On Wednesday the
laboratory is told the requester is nothing at all, because Fatima has no
`hcp_id`. On Thursday there is a potassium of 6.8 and **nobody to call**. Had
Fatima been a nurse — someone who *does* have a provider row — they would have
telephoned her instead, about a patient she has never assessed.

### The doctor's token will not survive the workflow, and must not need to

Worth stating because it is the reason the rule is not merely a preference.

By the time an insurance-held order is published, the token that authorised it is
gone — three separate ways, any one of which is enough:

- **It expired.** IAM issues a 24-hour TTL. A three-day approval outlives it.
- **It was replaced.** The estate stores one `token` field per user at
  `user:{usr_id}`, so the doctor signing in on a second device ends the first
  session. A ward round is enough.
- **They logged out**, went off shift, or left the organisation.

So there is nothing to re-authenticate against at dispatch. That is not a gap —
it is the correct behaviour of a session, and it makes the distinction explicit:

| | Question | Lifetime |
|---|---|---|
| **Authentication** | "are you who you claim, *right now*?" | the session |
| **Attribution** | "who decided this, *then*?" | the clinical record, permanently |

The clinician on an order is **attribution**. It was verified once, when the
doctor was present and their token was live, and from that moment it is a
recorded fact — not a credential to be re-checked. Nothing downstream needs the
doctor's session, because nothing downstream is claiming to be the doctor.

Two anti-patterns this rules out, and both get invented by someone trying to make
the identity "survive":

- **Storing the doctor's token to replay at dispatch.** A bearer credential
  persisted for days, valid for every service in the estate (HS256 with no
  `aud` — finding 10), sitting in a workflow table. Do not.
- **A service impersonating the doctor** to publish on their behalf. Same
  problem with extra steps.

The relay that publishes to Kafka **has no user at all**, and that is correct. It
is a machine moving a committed row; the identity it carries came from the row,
not from a caller. This is also why the failing line is so tempting: at dispatch
there is no doctor to read, so `req.user` is the only identity in scope — and it
belongs to whoever is advancing the workflow.

## Send `license_number` too

`hcp.id` means nothing outside your estate. A laboratory technician reconciling
provider records, and a regulator asking who ordered a test, both work from a
licence number. It goes as a second `Practitioner.identifier` and costs nothing.

## A user with no provider row must not become a clinician

A receptionist or ward clerk has an account and no `hcp` row. Their order should
still reach the laboratory — a missing name is a gap in the record, not a reason
to withhold a test — but **the account must not be substituted for a doctor.** A
login printed on a laboratory report as though it were a person is a false
clinical attribution, and worse than an empty field.

Worth deciding on your side: if non-clinicians cannot place orders at all in
your HIS, refuse at the API instead of degrading. The sandbox degrades because it
cannot know your policy.

## Names the laboratory will refuse

OpenELIS validates every name it stores against a configurable character set. The
default, and what our instance runs:

```
site_information.lastNameCharset = .'a-zàâçéèêëîïôûùüÿñæœ -
```

Letters including the accented Latin range, space, apostrophe, dot, hyphen.
**No digits.** It applies to `patients.first_name` / `last_name` and to
`hcp.name`.

For Latin names this is a non-issue — Konaté, N'Diaye, Diallo-Sow all pass. The
live risk is narrow and worth knowing rather than guarding:

- **A digit in a name field.** Usually a data-entry accident or a test record
  that reached production. We hit it building this sandbox: a patient called
  `Probe233437` made the import throw, and because a failed import is never
  acknowledged the same order was retried every 30 seconds indefinitely — one of
  those passes created a duplicate patient record. So the cost is not a rejected
  order, it is a retry loop in someone else's system.
- **Characters outside that range**, if a site is ever added whose names need
  them. `name_ar` and `first_name_ar` are in that category and cannot be what
  travels; send the Latin columns, which your schema already makes `NOT NULL`.
  Not a concern while the estate is Latin-only.

The charset is per-site and readable at runtime — OpenELIS publishes the compiled
regexes as `FIRST_NAME_REGEX` and `LAST_NAME_REGEX` on
`GET /rest/configuration-properties`, the same endpoint the catalogue sync
already calls. If a name ever does need rejecting before dispatch, discover the
rule from the laboratory rather than hardcoding a copy that will drift.

## One name, one chance

`hcp.name` is a single column, and OpenELIS **copies a practitioner on first
import and never refreshes it** (`docs/upstream-issues/05-...`). Between them:
however `hcp.name` is spelled the first time that clinician orders a test, that
is what the laboratory prints from then on. A later correction never arrives.

Write `hcp.name` the way it should appear on a laboratory report.

## The referring site: a stable key per branch, ward and business unit

The laboratory also needs to know **where the order came from** — its *Referring
Site*, which decides where the report goes back and who gets telephoned about a
problem. This is now implemented: the bridge publishes the site as a FHIR
`Location`, and OpenELIS creates its own referring-clinic organization from it on
first import, keyed on the Location's UUID for ever after.

"For ever after" is what makes this a schema question rather than a mapping one.
Reading `org-setup-service`'s own Prisma schema:

```prisma
model mlh_his_org_setup_branches       { id Int @id @default(autoincrement())  code String   name String? }
model mlh_his_org_setup_wards          { id Int @id @default(autoincrement())  code String   name String? }
model mlh_his_org_setup_business_units { id Int @id @default(autoincrement())  code String?            }
```

**Send `{table}|{id}`, not the code.** Three properties of your own schema decide
it, and each on its own is disqualifying:

| | Consequence |
|---|---|
| `code` has **no unique constraint** anywhere in the 50-model schema | nothing stops two branches sharing a code, and a key that can collide is not a key |
| `code` is **nullable** on `business_units` | a department may have no code at all |
| ids are **per table** | branch 5 and ward 5 are different places, so the table name has to be part of the key |

Identity must also survive a rename and a code edit, because a changed key grows
a **second** clinic in the laboratory's records for a place that already had one
and silently splits that site's report routing in half. The autoincrement id is
the only thing that never changes.

### Two things worth changing on your side

**`name` is nullable on all three, and `business_units` has none at all.**
OpenELIS guards only the name assignment, so a Location with no name still
creates the organization — an unnamed one, which the accessioner reads as a blank
field indistinguishable from a rendering fault. The bridge therefore sends **no
Location** rather than a nameless one, which leaves the technician typing it.
Making `name` required is a one-line migration and removes the case.

Note the asymmetry on wards: `name_ar` is **non-null** while `name` is nullable,
so an Arabic-only ward is valid in your schema today. The laboratory stores Latin
script only, so such a ward has nothing that can be sent.

**The site code is still worth carrying.** It rides on `Location.identifier`,
where a technician reconciling records can read it, while identity rests on the
derived UUID. You lose nothing by keying on the id.

---

# Part 3 — What the sandbox took from you

Conventions adopted deliberately, so the two estates stay legible to each other:

- **Topic naming** — `<domain>.<aggregate>.<event>`, so `lab.order.created` sits
  beside `billing.orders.order-created`
- **Log envelope** — `{service, level, message, timestamp}` on the shared `logs`
  topic
- **Service layout** — `app.ts`/`server.ts`, `config`/`core`/`shared`/`modules`,
  static containers with lazy singletons, `HTTPError`, Zod validators
- **Consul registration** — the same tags, check interval and deregistration
  window
- **Auth** — HS256 verification plus the Redis revocation check, and the
  degraded-mode fallback, with the three corrections in findings 5, 7 and 8

One difference left deliberately: the sandbox uses a DLQ **per topic**
(`<topic>.dlq`); you use one shared `billing.orders.dlq`. Either works — worth
picking one estate-wide.

---

# Part 4 — Two things the laboratory imposes on your HIS

Neither of these is a defect in your code. Both were found by running real orders
against a real OpenELIS, and both are the kind of thing that is obvious in
hindsight and expensive to discover in production.

## A patient name containing a digit loses the order, silently

OpenELIS validates incoming names against a configured character set. The default
is:

```
.'a-zàâçéèêëîïôûùüÿñæœ -
```

Letters, space, apostrophe, dot, hyphen. **No digits.** A patient whose surname
contains one fails validation on import, and the order simply stays at
`SENT_TO_LIS`. There is no rejection, no dead letter, and nothing in the HIS to
look at — the order is accepted by everything and worked by nobody.

We hit this by accident: a test script made patient names unique by appending a
unix timestamp, and its order vanished into the laboratory with no explanation
until we checked the character set.

**Why this will happen to you.** Registration desks produce names with digits
more often than anyone expects:

- **Disambiguation conventions** — `Doe 2`, `Traore 3` when two patients share a
  name and the clerk needs to tell them apart.
- **Placeholder records** — `UNKNOWN-4`, `Baby of Diallo 2`, trauma admissions
  registered before an identity is known.
- **Merged or duplicate records** carrying a suffix from the merge.
- **Identifiers that have leaked into a name field**, which happens in every
  system that has been running long enough.

**What to do.** Do not hardcode the character set — read it. OpenELIS exposes it
at runtime:

```
GET /rest/configuration-properties
→ FIRST_NAME_REGEX, LAST_NAME_REGEX
```

Validate against the laboratory's actual rule **at registration**, where a human
is present and can fix it. Discovering it at the laboratory means discovering it
where nobody can.

Note the asymmetry: this is the laboratory's rule, not yours, and it applies to
every patient you might ever send. It is worth treating as a registration
constraint in the HIS rather than as an integration concern, because by the time
it is an integration concern the order is already lost.

## A corrected patient name never reaches the laboratory

Once OpenELIS has imported a patient, it never updates its copy. Every later
order finds the stored patient by identifier and reuses it as it is; the incoming
demographics are discarded, and no new version is written.

So a name corrected in your HIS — a transliteration fixed, a married name, a
transposition caught at the desk — stays wrong in the laboratory for ever. The
specimen label and the report both carry the name OpenELIS first saw.

Verified end to end, not inferred: the bridge published the corrected surname,
the second order imported successfully, and OpenELIS still held the original with
one version in its FHIR store. Full write-up in
[upstream-issues/07](upstream-issues/07-patient-name-never-refreshed.md).

**There is no workaround inside the integration.** Re-sending is precisely what
does not work — that is the bug.

**What your HIS should do about it.** Two things, and the first matters more:

1. **Do not let a user believe the correction propagated.** When someone edits a
   patient who has laboratory orders, tell them the laboratory holds a separate
   copy that this will not change. Silence here is what turns a known limitation
   into a misidentification incident.
2. **Give them the out-of-band path.** Whoever makes the correction needs to know
   who to tell in the laboratory, and that this is a real step rather than
   paperwork. In practice: the laboratory edits the patient in OpenELIS itself.

The same defect affects the ordering **clinician's** name
([05](upstream-issues/05-practitioner-name-never-refreshed.md)). That one is a
reconciliation nuisance. The patient one is a patient-identification risk, which
is why it is worth a workflow rather than a note.


---

# Sequencing

Not by severity — by dependency, and by what makes the next step safe.

| Order | Do | Why first |
|---|---|---|
| 1 | **5** `decode` → `verify`, and **6** the fallback secret | One word and one line. Everything else about identity is unsound until these are done |
| 2 | **7** `enableOfflineQueue: false` | One line, and it must land *before* anyone adds degraded mode to the two services in #5 — that combination is the dangerous one |
| 3 | **2** DLQ `retryCount`, **4** idempotent producer | One line and two lines, no design work, immediate benefit |
| 4 | **3** let `send` reject | Touches every service, so it needs a coordinated release — but #1 is silent until it is done |
| 5 | **8** log transitions, add the metric | Makes the outage behaviour from #7 visible |
| 6 | **1** transactional outbox | Design change. Reference implementation in `services/his-api` |
| 7 | **9** routing-table registration | Before any service joins a second network, not after |
| 8 | **Audit trail** | Needs #1's outbox pattern and #5's verified identity |
| 9 | **10** RS256 and `aud` | Largest change, and the only one that is purely IAM's |

Items 1–3 are roughly an afternoon between them and remove the two ways an order
is currently lost silently.

---
