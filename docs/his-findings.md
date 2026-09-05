# Findings and recommendations — the real HIS

Everything the OpenELIS sandbox turned up that applies to **your** codebase
rather than to the sandbox, in one place.

None of it came from reading documentation. Each item was found either by
reading `HIS Project` source directly, or by hitting the same problem while
building the sandbox against your stack — and where the sandbox fixes something,
there is working code to copy, not a snippet.

**How to read this.** Part 1 is defects: things that are wrong now. Part 2 is a
design for something you do not have yet and will be asked for. Part 2b is what
an outside laboratory will ask of `org-setup-service`, including one place where
the natural choice is the wrong one. Part 3 is what the sandbox took *from* you.

---

## Summary

| # | Finding | Where | Consequence | Effort |
|---|---|---|---|---|
| 1 | No transactional outbox | `patient-service` visits module | An order exists and billing never hears about it | Design change |
| 2 | Dead-letter queue is unreachable | `order-fulfillment.consumer.ts:24` | A poison message blocks its partition for ever | **One line** |
| 3 | Failed publish looks successful | `config/kafka.ts` — every service | Callers cannot retry what they cannot see fail | Small |
| 4 | Producer not idempotent | `config/kafka.ts` — every service | A retry can overwrite a newer status with an older one | **Two lines** |
| 5 | `jwt.decode` instead of `jwt.verify` | `org-setup-service`, `file-upload-service` | Signature unchecked, expiry ignored | **One word, twice** |
| 6 | Hardcoded fallback signing secret | `file-upload-service/.../file-auth.middleware.ts:8` | Unset variable ⇒ links signed with a public string | **One line** |
| 7 | Degraded mode does not degrade | `config/redis.ts` — every service | A Redis outage hangs requests instead of bypassing the check | **One line** |
| 8 | Outage logs once per request | `auth.middleware.ts` | Thousands of identical lines/min on the shared topic | Small |
| 9 | Consul registration takes `eth0` | `config/consul.ts` | Breaks the moment a service joins a second network | Small |
| 10 | HS256 with no `aud` | `iam-service` | Every verifier can mint; nothing scopes a token to one service | Design change |

Items 5, 6 and 7 interact and are the ones to take first — see **Sequencing** at
the end.

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

**Where:** `config/kafka.ts` — `KafkaProducer.send()`

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

**Where:** `config/kafka.ts` — `this.producer = this.kafka.producer();`

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
```

If that variable is ever unset — a new environment, a renamed key, a typo — file
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

The same lesson bit the sandbox from the other direction: ASP.NET's four
Information lines per request, plus a 10-second Consul check, put **~2,800
messages in five minutes** on the shared topic from an idle service. Filtering
framework categories to Warning and above took it to 21.

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

How long that takes is not fixed:

| Patient | Order written → published |
|---|---|
| fully insured, clean approval | a minute or two |
| approval pending | hours, or two to three days |
| expired, re-created by a supervisor once approval lands | days, and by a **different person** |

The rule:

> Once the order row exists, the ordering clinician is read **from the order
> row**. Never from the session of whoever advances the workflow.

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

## The Latin name columns are load-bearing for the laboratory

OpenELIS validates names against a configurable character set. The default, and
what our instance runs, is Latin only:

```
site_information.lastNameCharset = .'a-zàâçéèêëîïôûùüÿñæœ -
```

No Arabic. No digits. That applies to `patients.first_name` / `last_name` and to
`hcp.name` — so `first_name_ar`, `last_name_ar` and `name_ar` cannot be what
travels.

Your schema has this right: the Latin columns are `NOT NULL` and the `_ar` ones
optional, so a usable name always exists. But nothing at the database level stops
a site typing Arabic into a Latin column, and when that happens **the order is
refused inside the laboratory**, at accessioning, in front of a technician who
cannot fix it. Your HIS reports success. Worth a validation at entry.

## One name, one chance

`hcp.name` is a single column, and OpenELIS **copies a practitioner on first
import and never refreshes it** (`docs/upstream-issues/05-...`). Between them:
however `hcp.name` is spelled the first time that clinician orders a test, that
is what the laboratory prints from then on. A later correction never arrives.

Write `hcp.name` the way it should appear on a laboratory report.

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
