# Kafka findings — HIS patient-service

Four defects found while aligning the OpenELIS sandbox with the real HIS
messaging layer. All four are in `HIS-patient-service-develop-2`; two of them
also affect every other service that uses the shared `config/kafka.ts`.

Ordered by consequence. Effort varies a lot — **#2 is a one-line fix**, #1 is a
design change.

Worth saying up front: the newer `OrderFulfillmentConsumer` already has the
right shape — Redis-backed idempotency keyed on `idempotency_key`, and a DLQ
path. The problems below are wiring and defaults, not misunderstanding.

---

## 1. Orders can be silently lost — no transactional outbox

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

The sandbox implements this end to end — `services/His.Api/OutboxRelay.cs` and
`db/his/002_outbox.sql` — and `make negative` proves it by stopping the broker
mid-flight: orders are still accepted, the event is queued durably, nothing is
marked failed, and the relay drains it unattended when Kafka returns.

---

## 2. The dead-letter queue is unreachable

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

## 3. A failed publish looks exactly like a successful one

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

## 4. Producer is not idempotent, so retries can reorder

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

### Related: the idempotency key changes on retry

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

## Infrastructure notes

Not defects, but worth a decision:

| | Current | Note |
|---|---|---|
| Broker image | `apache/kafka:latest` | Unpinned — a rebuild can change your broker version with no commit. Pin it. |
| Replication | RF 1, single broker | A broker failure loses messages regardless of `acks`. Needs 3 brokers with `min.insync.replicas=2`. |
| `min.insync.replicas` | not set | Without it, `acks=-1` can mean "the one replica that was up". |
| Auto-create topics | enabled | A typo in a topic name silently creates a topic nobody consumes. |

## Two conventions the sandbox adopted from you

- **Topic naming** — `<domain>.<aggregate>.<event>`, so `lab.order.created`
  sits beside `billing.orders.order-created`
- **Log envelope** — `{service, level, message, timestamp}` on the shared
  `logs` topic

One difference left deliberately: the sandbox uses a DLQ **per topic**
(`<topic>.dlq`), you use one shared `billing.orders.dlq`. Either works; worth
picking one estate-wide.

## Two event shapes are in circulation

`billing.visit.create-requested` carries a full envelope —
`event_id`, `event_type`, `event_version`, `occurred_at`, `source`, `key`,
`data` — and `config/kafka.ts` has a compatibility branch that upgrades the old
flat format to it.

The order path does not use that envelope. Since the newer shape has
`event_version` in it, adopting it consistently is what makes the *next* schema
change survivable.
