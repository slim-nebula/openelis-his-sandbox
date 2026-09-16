# Durability

Can a restart lose a lab order?

**No.** Not the bridge restarting, not OpenELIS restarting, not the HIS, not
Kafka, not a database. This document says why for each one, what the limits
honestly are, and how to prove it yourself in about twenty-five minutes.

The rule the whole design rests on: **an order is never in flight in anybody's
memory.** At every moment it is a committed database row or an uncommitted Kafka
offset — two things that survive `kill -9`. A process restarting has nothing to
drop, because it was never holding anything.

```bash
make restart          # the suite that proves it, with real orders
```

---

## 1. Where an order actually is, moment by moment

Follow one order from the doctor's screen to the bench. At each hop, the
question is *"if everything died right now, who still has this?"*

| # | Hop | Held by | Survives a restart because |
|---|---|---|---|
| 1 | Doctor submits | `his.lab_orders` + `his.outbox`, **one transaction** | it is committed before the API returns |
| 2 | Outbox → Kafka | `his.outbox` row, still unpublished | the relay retries for ever; the row is only marked published after the broker acks |
| 3 | On the topic | Kafka log, `acks=all` | the offset is committed only after the bridge's database write succeeds |
| 4 | Mapped to FHIR | `bridge.fhir_resources` + `bridge.order_tracking` | plain Postgres rows |
| 5 | Collected by OpenELIS | `bridge.delivery_leases` + `clinlims.electronic_order` | the lease is a row with a clock, not a process |
| 6 | Result released | `clinlims` + the export window | see §4 — the window reopens on failure |
| 7 | Pushed to the bridge | `bridge.received_resources` | written on arrival, correlated later on a timer |
| 8 | Back to the HIS | `lab.result.released` on Kafka | same offset rule as hop 3 |

Two of these are worth saying out loud because they are the ones people get
wrong:

**Hop 1 is a single transaction.** The order and the event that announces it
commit together. There is no window where the HIS has an order that nobody will
ever be told about, and no window where an event exists for an order that was
rolled back.

**Hop 7 writes first and thinks later.** What OpenELIS pushes is stored the
instant it arrives; correlating it to a HIS order happens on a separate timer
over that mirror. So a bridge that restarts mid-correlation has lost nothing —
the report is already on disk, and the next sweep picks it up. This also handles
FHIR resources arriving in the wrong order, which they routinely do.

---

## 2. The bridge restarts

The case people worry about most, and the least eventful.

| Restarting while… | What happens |
|---|---|
| an order is on the topic, unconsumed | offset uncommitted → Kafka redelivers it |
| it is halfway through the consumer handler | the handler throws, the claim is released, redelivery genuinely retries |
| a Task is published and waiting | it is a database row; the next poll collects it |
| OpenELIS is mid-import over HTTP | the request is **drained**, not cut — see below |
| it holds a delivery lease | the lease is a row with an expiry; §3 |
| a result is waiting to be correlated | already in `received_resources`; the next sweep takes it |

**The consumer commits after the write, never before.** KafkaJS auto-commit only
commits once `eachMessage` resolves, so a crash mid-handler leaves the offset
where it was. Delivery is therefore *at-least-once*, and the bridge is built for
it: events are claimed by id, and FHIR resource ids are derived deterministically
from the order id. A replayed order produces an **update to the same Task**, not
a second one.

**In-flight requests are drained.** On `SIGTERM` the bridge deregisters from
Consul first, then leaves the consumer group, then closes the listeners and
waits for open connections to finish, with a five-second ceiling
([`server.ts:96`](../services/bridge/src/server.ts#L96)). An import that is
halfway through writing an order is not cut in two by a redeploy. The ceiling
exists because Docker sends `SIGKILL` at ten seconds regardless — better to exit
cleanly at five than be killed at ten.

**One deliberate non-behaviour:** the bridge never times out, cancels or expires
a published Task. A laboratory that is away for a day is a laboratory that is
away for a day; the order waits. Nothing in the bridge decides an order has been
outstanding too long — that judgement belongs to a human, which is what
`OrderUndelivered` and `make reconcile` exist to prompt.

**With one exception, and it is evidence rather than a timer.** If a *result*
comes back for an order whose Task is still `requested`, the Task is closed as
`completed`. The acknowledgement was lost — the laboratory evidently imported
the order, since it resulted it — and without this the poll re-offers a finished
order for ever. Two Tasks here reached 102 and 48 deliveries that way.

The close is guarded so it can only move a Task **out of** `requested` or
`received`, never over a verdict the laboratory actually gave, and it logs a
warning rather than passing in silence: a lost acknowledgement is a fault worth
seeing, not just worth tidying. Note that the alert was never the problem — the
undelivered-age gauge already excluded orders with a forwarded result — so this
fixes what the laboratory experiences, not what the dashboard showed. See
[operations.md](operations.md#an-order-was-resulted-but-the-task-is-still-being-offered).

---

## 3. The delivery lease, specifically

The lease is the one piece of state that *sounds* like it should be in memory,
so it is worth being explicit: it is not.

`bridge.delivery_leases` is a row per Task with a `leased_until` timestamp. The
claim query withholds a Task from later polls until that time passes. Which
means:

- **Restarting the bridge mid-import strands nothing.** The lease expires on the
  clock (`BRIDGE_TASK_LEASE_SECONDS`, default 90) whether or not the process that
  took it still exists. The Task is simply re-offered to the next poll.
- **Restarting does not duplicate anything either.** A second delivery of the
  same Task is an update to the same deterministic ids, and OpenELIS matches it
  to the electronic order it already has.
- **Releasing a lease is an `UPDATE`, never a `DELETE`.** `first_at`, `last_at`
  and `deliveries` survive the release, so an order that was collected five times
  and never acknowledged is visible afterwards rather than being tidied away.

`make restart` asserts this directly: it reads the lease row, restarts the
bridge, and reads it back unchanged.

---

## 4. OpenELIS restarts

Two directions, and they fail differently. This is the section worth reading
twice.

### Orders going out: nothing to lose

OpenELIS **pulls**. It polls the bridge for Tasks in `requested`; while it is
down it simply does not poll, and the Tasks sit exactly where they were. When it
comes back it polls again and collects them. There is no queue on the OpenELIS
side to lose, because the bridge is the queue.

The visible signal during the outage is `LaboratoryStoppedPolling`
([monitoring.md §4](monitoring.md#4-the-seven-rules)) — which fires on the poll
going quiet, without needing an order to exist.

### Results coming back: the window reopens on failure

This is the half that could have lost data, and does not.

OpenELIS pushes released results to the bridge on a timer (every minute here —
`clinlims.data_export_task.max_data_export_interval`). Each attempt is recorded
in `clinlims.data_export_attempt` as `SUCCEEDED` or `FAILED`. The question that
decides everything is: **after a failed push, what window does the next attempt
ask for?**

Verified from OpenELIS's own bytecode —
`DataExportServiceImpl.getBundlesFromLocalServer` builds it as:

```
lower bound (inclusive) = getLatestSuccessInstantForDataExportTask(task)
upper bound (inclusive) = this attempt's start time
```

and `DataExportTaskServiceImpl.getLatestSuccessInstantForDataExportTask` queries
attempts **filtered to `SUCCEEDED`**, falling back to `Instant.EPOCH` when there
has never been one.

Both classes ship inside `dataexport-api-0.0.0.9.jar` and
`dataexport-core-0.0.0.9.jar` in the OpenELIS webapp — read them the same way
this was read:

```bash
docker cp openelis-webapp:/usr/local/tomcat/webapps/OpenELIS-Global/WEB-INF/lib/dataexport-api-0.0.0.9.jar .
unzip -q dataexport-api-0.0.0.9.jar -d api
docker run --rm -v "$PWD:/w" -w /w eclipse-temurin:21-jdk \
  javap -p -c api/org/itech/fhir/dataexport/api/service/impl/DataExportServiceImpl.class
```

So the lower bound is the last **successful** push, not the last *attempt*. Every
failure widens the window rather than advancing it. A result released while the
bridge was down falls inside the next successful window and is re-sent. Nobody
replays anything by hand.

> This deployment has already lived it — repeatedly. Count them on your own
> stack:
>
> ```sql
> -- make psql-oe
> SELECT data_export_status, count(*) FROM clinlims.data_export_attempt GROUP BY 1;
> ```
>
> At the time of writing: **10 FAILED against 2260 SUCCEEDED**, and no result
> lost behind any of them. The most recent failure is the one `make restart`
> caused on purpose — a `FAILED` push at 02:39:50 whose preceding success was at
> 02:38:03, so the recovering attempt asked for everything from 02:38:03 onward
> and swept the outage up with it.

Two consequences worth carrying into production:

- **A long outage means a large recovery push.** The window is "everything since
  the last success", so a bridge down for a day produces a day-sized bundle when
  it returns. That is correct, and it is also the moment to have sized the
  bridge's request limits for it.
- **The fallback is the epoch, not "nothing".** A channel that has *never*
  succeeded asks for everything from `Instant.EPOCH`. Safe, but it means the very
  first successful push on a new deployment is the largest one it will ever do.

---

## 5. The HIS, Kafka and the databases

**his-api restarts** — its consumer commits offsets only after the database
write, same rule as the bridge. Unpublished `his.outbox` rows are picked up by
the relay on start. The one thing to check afterwards is that the consumer
actually resubscribed, because *alive* and *consuming* are different questions:

```bash
docker exec his-api curl -s http://127.0.0.1:8080/metrics | grep kafka_consumer_running
```

**Kafka restarts** — producers block and retry, the outbox backs up and drains,
consumers rejoin their group at their committed offsets. Topics are created with
`acks=all` and `min.insync.replicas`, so an acknowledged write is on disk.

**A database restarts** — both Postgres servers are on named volumes
(`his-db-data`, `openelis-db-data`) and `restart: unless-stopped`. Services
reconnect through their pools. This is the ordinary case and it needs no
commentary.

**Redis restarts** — deliberately unpersisted (`--appendonly no --save ""`).
Nothing clinical is in it. What is lost is the session-revocation set, so tokens
revoked by a logout become valid again until they expire on their own. The
metric is `auth_revocation_checks_total{result="degraded"}`. A security
consideration, not a data-loss one, and it is called out in
[security.md](security.md).

**Consul restarts** — dev mode, in memory, rebuilt by services re-registering. A
registry that survived with stale entries would be worse than one that starts
empty.

**Prometheus restarts** — two days of metrics on a volume. Losing them costs you
history, not orders. Clinical truth is in the databases and the ledger, never in
a time series.

---

## 6. What a restart CAN cost — the honest limits

Three real ones. None loses an order in normal operation, and all three are
worth knowing before go-live.

### `docker compose down` on Kafka is not the same as restarting it

The broker's log directory is left at the image default rather than on a named
volume — deliberately, because a named volume would be root-owned and the image
runs unprivileged
([`compose/platform.yml:103`](../compose/platform.yml#L103)). Data survives
`stop`/`start` and `restart`, which is what every restart scenario in this
document and in `make restart` actually exercises.

It does **not** survive removing the container. `docker compose down`, `docker rm`,
or `make clean` on the platform stack discards any event not yet consumed.

**For production: give the broker a named volume with the right ownership.** In
this sandbox the exposure is nil — `his.outbox` still holds every event, and
they are re-publishable — but do not carry the sandbox's default into a
hospital.

### Kafka retention is 7 days

`log.retention.hours=168`. An order sitting unconsumed for longer than a week is
deleted from the topic. In practice this needs the bridge to be down for seven
days, which `LaboratoryStoppedPolling` would have been shouting about since
minute five.

And even then the order is not *gone* — it is still in `his.lab_orders`, with a
status that never advanced. It never reached the laboratory, which is a
different and more recoverable problem than having been lost. `make reconcile`
is what finds it.

### A restart is invisible to the ledger, and that is the point

Metrics reset; the ledger does not. `make reconcile` is derived at read time from
`order_tracking`, `forwarded_results` and `dead_letters`, so it answers *"did
every order taken on that day get resulted"* across any number of restarts. After
an incident, that is the report to run — not a dashboard.

```bash
make reconcile DAYS=7
```

---

## 7. The one change to make for production

Everything above is either already right or explicitly sized for an 8 GiB
laptop. Exactly one item is a sandbox default that must not ship:

**Give Kafka a durable, correctly-owned volume.** Then `down` is as safe as
`restart`, and the seven-day retention becomes a policy choice rather than an
image default.

The rest — Alertmanager, remote-write, long-term retention — is in
[monitoring.md §8](monitoring.md#8-what-is-deliberately-missing).

---

## 8. Proving it yourself

```bash
make restart               # ~25 min: four restarts under live orders
make restart SKIP_OPENELIS=1   # ~10 min: skips the Tomcat restart
```

[`scripts/test-restart.sh`](../scripts/test-restart.sh) takes components away
underneath real orders and checks the orders arrive anyway:

| | Scenario | What it pins |
|---|---|---|
| **A** | the bridge is down when the clinician orders | the HIS still accepts; Kafka holds it; it is delivered on restart |
| **B** | the bridge restarts with a Task outstanding | Task and tracking survive; OpenELIS still collects it |
| **C** | a lease survives the restart that interrupted it | the lease is state, not memory, and releasing keeps the count |
| **D** | OpenELIS restarts with an order outstanding | the Task stays `requested`, and is collected when it returns |
| **E** | the result-push channel fails and recovers | the failure is recorded, and the channel heals unattended |

Section D restarts Tomcat, which is minutes rather than seconds — that is what
the runtime is, not a hang.
