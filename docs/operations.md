# Operations

Starting it, watching it, fixing it at 3am, and the platform contracts every
service here answers.

Written for whoever runs this, who may not be whoever wrote it. **Nothing below
requires reading the source.**

---

## 1. Startup

Order matters: the external database servers must accept connections before the
applications start, and the test menu must be synced before any order will be
accepted.

```bash
make up              # renders config → starts databases → builds and starts apps
make sync-catalogue  # read the orderable test menu from OpenELIS into the HIS
make smoke           # confirm the platform before sending clinical data
make token USER=42   # sign in — the suites own user 1, so browse on another id
```

`make up` is safe to re-run; it is idempotent.

### What happens, in order

| Step | What it does | How long |
|---|---|---|
| `secrets` | First run only: writes `.env` from `.env.example`, generating passwords and tokens | instant |
| `config` | Renders `openelis/generated/common.properties` from `.env`, and issues the CA and the bridge's server certificate | instant |
| `data-up` | Starts `his-db.external` and `openelis-db.external`, waits for `pg_isready` | 30 s first run, ~4 min for OpenELIS's schema load |
| `app-up` | Exports OpenELIS's certificate and imports our CA into its truststore, builds the HIS service and the bridge, then starts everything else | 3–6 min first run |
| OpenELIS boot | Tomcat, Liquibase migrations, FHIR store startup | 3–8 min under emulation |

The certificate work is split across two of those steps deliberately. The CA and
the bridge's own certificate depend on nothing, so they are made before the stack
starts — the bridge serves its FHIR port with one, and OpenELIS's truststore
needs the other imported before Tomcat reads it. OpenELIS's certificate cannot be
made early, because certgen has not created it yet; the `oe-peer-cert` one-shot
exports it from the volume the moment certgen exits, and the bridge waits for
that one-shot before starting.

Get that ordering wrong and a fresh clone comes up with a crashlooping bridge and
an OpenELIS that trusts nobody — which is to say, orders that never reach the
laboratory. It is verified by the only test that counts: `make clean`, delete
`certs/`, `make up`.

The OpenELIS webapp is ready when `docker logs openelis-webapp` shows
`Server startup in [n] milliseconds`. Until then the UI returns 502.

### First-run cost

The upstream OpenELIS images are large and `linux/amd64` only. On Apple Silicon
they are pulled and emulated. Pinned to a **named release**, never `:develop` —
`OE_VERSION` in `.env` is the single place it is set.

Allocate **at least 8 GB** to Docker Desktop. With less, the OpenELIS webapp and
its HAPI FHIR server compete for heap and the poll loop stalls. On an 8 GB host,
stop the stack before building anything large — `make openelis-patched` in
particular.

---

## 2. Daily use

```bash
make ps                 # container status across both projects
make logs S=bridge      # follow one service
make urls               # entry points and credentials
make topics             # Kafka topics
make psql-his           # psql on the HIS sandbox database
make psql-oe            # psql on the OpenELIS database
```

Bridge introspection, useful when an order seems stuck:

```bash
docker exec bridge curl -s -H "Authorization: Bearer $BRIDGE_ADMIN_TOKEN" \
  http://localhost:8080/ops/orders
docker exec bridge curl -s -H "Authorization: Bearer $BRIDGE_ADMIN_TOKEN" \
  http://localhost:8080/ops/dead-letters
# The order poll, exactly as OpenELIS issues it. Take the owner from .env rather
# than typing one: a value that does not match byte for byte returns an empty
# bundle, which looks identical to "no orders waiting".
docker exec bridge curl -s \
  "http://localhost:8080/fhir/Task?status=requested&owner=$OE_REMOTE_SOURCE_IDENTIFIER"
```

### Reaching `/ops` as a person

`/ops/*` takes either the shared operator token or a signed-in HIS user's token.
Prefer the user token: the shared secret then does not have to be passed around,
and the log records **who** ran the request.

```bash
TOKEN=$(scripts/mint-token.sh --quiet --groups lab-orders,lab-ops)
docker exec bridge curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/ops/export-status
```

---

## 3. Running the tests

| Phase | Command | Needs a human? |
|---|---|---|
| pure functions | `make unit` | no — and no stack either |
| platform smoke | `make smoke` | no |
| order flow | `make e2e` | no, up to LIS acceptance |
| lab workflow | `make e2e` (second half) | **yes** — release the result in the OpenELIS UI |
| everything else | the twelve suite targets | no |

`make e2e` drives the order into OpenELIS automatically, then pauses and waits
(default 10 minutes) for a lab user to accession, result, validate and release
it. Raise the wait with `RESULT_TIMEOUT=1800 make e2e`. Order a different test
with `scripts/test-order-flow.sh GLUC`.

### The manual lab steps

1. https://localhost — `admin` / `adminADMIN!`
2. **Order → Incoming Orders**, find the order number, accession it
3. **Work Plan** or **Results Entry** — enter a numeric value
4. **Validation** — validate and release

Release is what matters. The bridge forwards only `final`, `amended`,
`corrected` and `entered-in-error`, so an entered-but-unvalidated result stays in
the laboratory.

Latency from release to the HIS frontend is bounded by
`OE_SUBSCRIBER_BACKUP_INTERVAL` (default 1 minute) plus the bridge's 10-second
correlation sweep.

> **`make negative` is not safely re-runnable back to back.** It proves the
> outage paths by actually stopping Kafka, Redis, his-api and OpenELIS. A second
> run started before everything settles fails checks that have nothing to do with
> the code — we watched a clean 56/56 become 54, then 49, then 48 purely from
> compounding restart lag. Restart the stack between runs, or trust the first
> result.

---

## 4. The bridge, and why nothing has happened yet

The bridge holds no clinical decisions. Everything it does is translation and
bookkeeping. If it stops, nothing is lost — orders queue in Kafka and results
queue in OpenELIS. **What matters is how long it stops for**, not that it
stopped.

### The six things it does in the background

The first delay is measured from process start, so after a restart nothing below
has happened yet — which is the commonest reason a thing looks broken when it is
merely young.

| Worker | Cadence | What it does |
|---|---|---|
| Order consumer | continuous | reads `lab.order.created`, publishes a FHIR Task |
| Result correlator | every **10s**, first run 15s after start | matches pushed results to orders |
| Progress tracker | every **15s**, first run 20s after start | turns what OpenELIS pushes into `labProgress` and the accession number |
| Integration gauges | every **30s**, first run 20s after start | refreshes the four gauges the alerts read |
| Export monitor | every `EXPORT_CHECK_MINUTES` (**5m**), first run 1m after start | asks OpenELIS whether it is still pushing |
| Retention sweep | every `RETENTION_SWEEP_HOURS` (**24h**), first run 5m after start | deletes aged rows |

The gauges are the one to remember: they are **absent, not zero**, until that
first refresh succeeds. A `/metrics` scrape in the first twenty seconds after a
restart shows no `bridge_*` gauges at all, and that is deliberate — an absent
metric breaks an alert expression instead of answering it with a reassuring zero.

**OpenELIS polls on its own schedule**, which the bridge cannot hurry.
`OE_REMOTE_POLL_FREQUENCY` in `.env` is rendered into `common.properties`; this
stack runs **30 s**. Read the running value from the mounted file, not from the
copy inside the WAR, where the property is commented out and the compiled-in
fallback of 120 s applies instead:

```bash
docker exec openelis-webapp grep remote.poll.frequency /run/secrets/common.properties
```

---

## 5. Monitoring

### First five minutes of any incident

```bash
make alerts                # what does the system already know is wrong?
make ps                    # is it running, and is it healthy?
make logs S=bridge         # what is it saying?
make export-status         # is OpenELIS still pushing results to us? (checks now)
make dead-letters          # what failed in a way that needs a human?
```

`make alerts` goes first for a reason: the four gauges behind it are refreshed
every thirty seconds and cover exactly the failures that do **not** show up in a
log tail, because nothing errored.

`/health` returns **503 when it cannot reach its database**, on purpose. A 503
here is the service telling the truth — look at the database next, not at the
bridge.

### The alerts, and what to do about each

Prometheus scrapes the bridge, his-api and Kong every fifteen seconds and
evaluates [`monitoring/alerts.yml`](../monitoring/alerts.yml). There is no
Alertmanager and no pager — routing is a decision about who is on call, which
belongs to the hospital rather than to a sandbox. `make alerts` prints what is
firing; `firing` means the condition has held for the rule's `for:` window,
`pending` means it has just started.

Every rule here covers a **silent** failure. That is the entry requirement: if it
would already show as a 500 or a red container, it does not need an alert.

| Alert | What it means | First move |
|---|---|---|
| `OrderUndelivered` | an order has waited >15 min for the laboratory to collect it | `make export-status`, then `docker logs openelis-webapp`. The order is published and nobody has come for it |
| `LaboratoryStoppedPolling` | no poll for >5 min | OpenELIS is down, or the mTLS handshake is failing — §7. Fires *before* `OrderUndelivered` because it does not need an order to exist |
| `DeadLettersGrowing` | new failures in the last hour | `make dead-letters`, then §7 |
| `CatalogueStale` | the test menu is >45 days old | `make sync-catalogue` and **read the diff** |
| — | *(no alert)* a synced test nobody has priced | `make sync-catalogue` now prints billing coverage; see [billing-integration.md](billing-integration.md) |
| `CatalogueNeverSynced` | no menu at all | `make sync-catalogue`. Until it runs, nothing is orderable |
| `ServiceDown` | Prometheus cannot scrape a service | while this fires, every other alert on that service is **blind, not quiet** |
| `ResultConsumerNotRunning` | his-api is up but not consuming | results are piling up on the topic and reaching no patient record. Restart his-api; the consumer retries on its own but a stuck one needs a push |

Two properties of this setup are worth knowing before you trust it.

**A gauge that has never refreshed is absent, not zero.** The bridge publishes
nothing until its first successful database read. This was learned the hard way:
an early version had a query that always threw, so all four gauges sat at their
registered default of `0`, which reads as "nothing stuck, no dead letters,
catalogue fresh". The most alarming possible state produced the most reassuring
possible numbers. An absent metric breaks the alert expression instead of
satisfying it, which is what you want.

**A rule can be healthy and still never fire.** Prometheus reports a rule as `ok`
if it *parses*, whether or not the metric it names exists — so renaming a gauge
silences its alerts permanently behind a green rules page. `make monitoring`
checks that every metric referenced by every alert still resolves to a real
series, which is the only way to catch that.

```bash
make monitoring            # 16 checks: collector, gauges, rules, and the fire path
```

The collector itself — what it scrapes, what every metric means, how to add a
rule, and what is deliberately missing — is in
[monitoring.md](monitoring.md). Prometheus is at **http://localhost:9090**.

### The daily glance: does it add up?

Alerts answer *"is something wrong now"*. They cannot answer *"did everything we
accepted last week actually get a result"* — a slow leak of one order a day
crosses no threshold, because the oldest-undelivered age keeps being reset as
stuck orders are resolved or swept. Nothing notices until somebody counts.

```bash
make reconcile             # last 7 days
make reconcile DAYS=30
```

```
    14 days: 284 taken on | 272 accepted | 10 rejected | 5 resulted | 2 outstanding (1 over a day) | 10 dead
    day            on   acc   rej   res   out   >1d  dead
    2026-09-09      5     3     1     0     1     0     1
    2026-09-07     21    21     0     2     0     0     0
```

Read it right to left. **`>1d` is the column that matters** — an order
outstanding for minutes is ordinary in-flight traffic; one outstanding overnight
is a patient whose test nobody is running. `dead` alongside it says whether the
shortfall was at least *recorded* as a failure or simply vanished.

A large gap between `acc` and `res` is normal in this sandbox and **not** normal
in a laboratory: here most orders are placed by test suites and never worked. In
a real deployment that gap is the backlog, and it should close within a working
day for routine tests.

Everything in the report is derived from `order_tracking`, `forwarded_results`
and `dead_letters` at read time. Nothing is written to produce it, which is why
it cannot drift from the data it describes.

---

## 6. Things not to do

**Do not restart the bridge to "clear" a stuck order.** Nothing is held in
memory. The state is in Postgres and Kafka, and a restart replays the same work.

**Do not run a broad `GET /fhir/Task` to see what is queued.** The order-poll
search *takes a delivery lease on everything it returns* — that is how it stops
OpenELIS importing one order twice — so a wide search withholds those Tasks from
the laboratory for `BRIDGE_TASK_LEASE_SECONDS` (90 by default). Debugging the
queue this way stalls it. We did this while testing and blanked 562 Tasks for a
minute and a half.

Use the paths that deliberately take no lease:

```bash
docker exec bridge curl -s "http://127.0.0.1:8080/fhir/Task/<id>"      # read, no lease
docker exec bridge curl -s "http://127.0.0.1:8080/fhir/Task?_id=<id>"  # same
make psql-his   # then query bridge.fhir_resources directly
```

**Do not delete rows from `bridge.fhir_resources`.** It is what OpenELIS *reads*
— an order it has not polled yet, a ServiceRequest it dereferences when a late
report arrives. It is deliberately excluded from the retention sweep.

**Do not set `BRIDGE_FHIR_ALLOWED_PEERS` to empty to fix a 403.** That opens the
result-injection path to everything on the network. See §9, *Adding a new FHIR
peer*. With mutual TLS on, that list no longer governs the live path anyway — a
403 there is far more likely to be the one below.

**A 403 saying "requires a mutually authenticated TLS connection" is correct
behaviour.** Something reached `/fhir` on the plaintext port. Find out what, and
point it at `https://bridge.openelis.org:8443/fhir` — do not turn mutual TLS off
to make it go away. `bridge_fhir_requests_total{transport="plaintext"}` counts
these.

**Do not regenerate the certificates to fix a handshake failure.** A new CA is
one OpenELIS's truststore does not contain, so it converts a handshake problem
into a definitely-broken link. `make certs` deliberately keeps what exists; if
you do regenerate with `FORCE=true`, `make trust-bridge` must follow.

**Do not put a token on `/fhir`.** OpenELIS cannot send one — the integration
would stop, silently. [security.md §3](security.md#3-why-the-fhir-endpoint-has-no-token--and-how-it-is-secured-instead)
has the evidence.

**Do not reset consumer offsets to unstick a consumer.** That either replays
orders or skips them, depending on the reset policy.

**Do not edit anything in OpenELIS to make the bridge's job easier.** It is the
accredited component. Every asymmetry in this design exists because of that.

---

## 7. Recovery

### `.env` has been lost, but the stack is still running

**Do not run `make secrets`.** It generates fresh passwords and tokens, and the
databases already exist with the old ones — you would be locked out of your own
data.

The running containers hold every resolved value, so recover from them instead:

```bash
# every variable the stack actually resolved, deduplicated
for c in $(docker ps --format '{{.Names}}'); do
    docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}'
done | grep -E "^[A-Z][A-Z0-9_]*=" | sort -u
```

Most keys map straight across. These do not, because compose renames them or
folds them into a connection string:

| `.env` key | where it actually lives |
|---|---|
| `HIS_DB_ADMIN_PASSWORD` | `his-db-external` → `POSTGRES_PASSWORD` |
| `OE_DB_PASSWORD`, `OE_DB_SUPERUSER_PASSWORD` | `openelis-db-external` → `DB_PASSWORD`, `DB_SUPERUSER_PASSWORD` |
| `SSL_KEYSTORE_PASSWORD`, `SSL_TRUSTSTORE_PASSWORD` | `openelis-certs` → `KEYSTORE_PW`, `TRUSTSTORE_PW` |
| `BRIDGE_DB_USER` / `_PASSWORD` / `_NAME` | inside `bridge` → `BRIDGE_DB_CONNECTION` |
| `HIS_DB_USER` / `_PASSWORD` / `_NAME` | inside `his-api` → `HIS_DATABASE_URL` |

Fill the rest from `.env.example`, whose defaults are the non-secret ones. Then
prove it before trusting it:

```bash
make smoke && make auth && make negative
```

*This is written from having done it.* `.env` used to be tracked in git and was
later removed; checking out a commit from before that removal overwrote the real
file, and the next merge deleted it. Nothing was lost because the stack was up.

### An order is sitting at `AWAITING_COLLECTION`

**Check this first, and do not escalate it as an integration fault.** It is the
one state in which nothing has been sent to the laboratory — no outbox row, no
Kafka event, no FHIR Task. Every other stalled state means a system did not do
its job. This one means **a specimen has not been drawn**, and no amount of
restarting anything will move it.

```sql
-- make psql-his
SELECT order_number, patient_class, created_at, now() - created_at AS waiting
  FROM his.lab_orders
 WHERE order_status = 'AWAITING_COLLECTION'
 ORDER BY created_at;
```

Only inpatient orders reach it. If an **outpatient** order is here, that is a
genuine fault — it should have dispatched at creation.

The fix is a clinical action, not an operational one: the ward records the draw,
which writes the collection time and queues the dispatch in one transaction.

```bash
curl -sf -X POST -H "Authorization: Bearer $HIS_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"collectedAt":"2026-09-02T06:15:00Z"}' \
  http://localhost:8090/api/lab-orders/LAB-YYYYMMDD-XXXXXXXX/collection
```

**Do not "unstick" one of these by hand in the database.** Setting the status to
`CREATED` without an outbox row produces an order that will never be sent and now
looks dispatched — strictly worse than the state you started in. Writing the
outbox row without a collection time sends the laboratory an order whose whole
reason for waiting has been lost. They commit together for exactly this reason.

There is deliberately **no automatic timeout**: expiring a real pending order
because a nurse was busy would be worse than leaving it visible.

### One order is stuck at `SENT_TO_LIS` and the others are fine — check the patient's NAME

**OpenELIS rejects patient names containing digits**, and the failure is silent
from our side. Found the hard way: a fixture named `Probe233437` produced

```
Validation failed for classes [org.openelisglobal.person.valueholder.Person]
'invalid name format, possibly illegal character', propertyPath=lastName
```

and then, on every poll, for ever:

```
FhirApiWorkFlowServiceImpl, beginTaskImportOrderPath,
Error: could not process Task with identifier : …/Task/<uuid>
```

The Task is never acknowledged, so it stays `requested` and the next poll picks
it up again — the retry loop from
[defect 01](upstream-issues/01-task-poll-not-idempotent.md). **Nothing reaches
the HIS.** The order sits at `SENT_TO_LIS` indefinitely with no rejection, no
dead letter and no failure status, because from our side the Task was published
successfully and simply never came back.

```bash
docker logs openelis-webapp --since 30m 2>&1 | grep -i "invalid name format"
```

The fix is in the patient record, not the integration: correct the name in the
HIS and place a new order. The stuck Task keeps retrying until OpenELIS is
restarted or the resource is removed.

Worth designing around in a real HIS: placeholder names for unidentified patients
(`Unknown 47`, `Baby of Ward 3`), house numbers accidentally typed into a name
field, and some transliterations will all trip this.

### An order is stuck at `SENT_TO_LIS`

The bridge has published the Task but OpenELIS has not imported it.

```bash
docker exec bridge curl -s -H "Authorization: Bearer $BRIDGE_ADMIN_TOKEN" \
  http://localhost:8080/ops/orders
docker logs openelis-webapp 2>&1 | grep -iE "task|remote" | tail -40
```

- Task not in `/ops/orders` → the bridge never processed the event. Check
  `make logs S=bridge` and the consumer group lag.
- Task present but OpenELIS logs nothing → OpenELIS cannot reach the bridge.
  Verify: `docker exec openelis-webapp curl -sf http://bridge:8080/fhir/metadata`
- **Task present, OpenELIS reachable, and the poll returns `0 match(es)`** → the
  two sides disagree about the laboratory's address. This is silent on both
  sides: the bridge answers correctly, OpenELIS asks correctly, and the answer is
  legitimately empty.

  ```bash
  # What OpenELIS is asking for — the RUNNING value, which a container started
  # before the last `make config` will not have.
  docker exec openelis-webapp grep remote.source.identifier /run/secrets/common.properties
  # What the bridge is stamping, and on how many undelivered orders.
  docker exec bridge curl -s "http://127.0.0.1:8080/fhir/Task?status=requested" \
    | grep -o '"reference":"[^"]*"' | sort | uniq -c
  ```

  If they differ, the usual cause is a changed `OE_REMOTE_SOURCE_IDENTIFIER` with
  undelivered orders left behind. Move them onto the current address — bridge-side
  resources only, nothing inside OpenELIS changes:

  ```sql
  -- make psql-his, on the bridge database
  UPDATE bridge.fhir_resources
     SET content = jsonb_set(content, '{owner,reference}', '"Organization/<current-uuid>"')
   WHERE resource_type = 'Task' AND content ->> 'status' = 'requested';
  ```

**If OpenELIS logs the same failed import over and over, that is the known
upstream defect and it will not stop on its own.** A Task whose import throws is
never acknowledged, so it stays `status=requested` and the next poll picks it up
again — one clean rebuild left a single order being re-imported every 30 seconds
for twenty-six minutes, and one of those passes created a **duplicate patient
record**. Full evidence:
[defect 01](upstream-issues/01-task-poll-not-idempotent.md).

```bash
# Is this happening? A count that keeps climbing for one Task is the signature.
docker logs openelis-webapp --since 10m 2>&1 | grep -c "could not process Task"
```

To stop the loop, take the order out of the poll's result set — the Task is the
bridge's own resource, so this changes nothing inside OpenELIS:

```sql
-- make psql-his, on the bridge database
UPDATE bridge.order_tracking SET task_status = 'failed', last_error = 'import loop, see operations'
 WHERE order_number = 'LAB-...';
```

Then check `clinlims.patient` for duplicates created by the retries, and tell the
laboratory: merging patient records is theirs to do, not ours.

**What the bridge does about it.** A Task handed to the laboratory is withheld
from the next polls for `BRIDGE_TASK_LEASE_SECONDS` (90 by default), so OpenELIS
cannot be given the same order twice at once. That removes the collision — the
409 and the duplicate patient both need two overlapping imports — without
touching the Task, which stays `requested` and stays readable by id.

`deliveries` is the attempt counter OpenELIS does not keep. It is the fastest way
to tell a slow laboratory from a failing import:

```sql
-- make psql-his, on the bridge database
SELECT l.resource_id, l.deliveries, l.first_at, l.last_at, t.order_number
  FROM bridge.delivery_leases l
  LEFT JOIN bridge.order_tracking t ON t.fhir_task_id = l.resource_id
 WHERE l.deliveries > 1 ORDER BY l.deliveries DESC;
```

One delivery is normal. A number climbing steadily means the laboratory takes the
order and never returns a verdict.

> **Still an open decision.** The lease stops orders colliding; it does not stop
> them being retried for ever. A mediator arguably also owes the HIS a delivery
> timeout — after N attempts, give up, publish `lab.order.failed`, stop offering
> the Task. That is deliberately **not** built: abandoning a clinician's order
> automatically is a clinical safety decision, not one to make on the sandbox's
> own authority. `deliveries` gives you the number to set the threshold from.

### An order was rejected

**First: `rejected` does not reliably mean the laboratory refused it.** A
rejection caused by an internal OpenELIS failure leaves the order at `Entered`,
not `NonConforming`:

```sql
-- make psql-oe :  21 = Entered (accepted), 24 = NonConforming (genuinely refused)
SELECT external_id, status_id FROM clinlims.electronic_order
 WHERE external_id = 'LAB-...';
```

`21` means the laboratory has the order and something else set the Task to
rejected — look at `docker logs openelis-webapp` for an exception at that
timestamp, not at the catalogue. `24` is a real refusal; continue below.

Almost always test identity. Confirm the LOINC exists on an OpenELIS test:

```bash
make catalogue          # what the HIS currently offers
make sync-catalogue     # re-read it from OpenELIS (also reports billing coverage)
docker logs bridge --since 10m | grep -E 'is claimed by|OpenELIS catalogue:'
```

The sync logs each collision by name and a one-line summary of what it filtered
and why. A test is offered only if it is active, orderable, holds exactly one
LOINC and carries a sample type with a local abbreviation. Resolve it in OpenELIS
under *Administration → Test Management*, then sync again.

### A released result never arrives

```bash
docker logs bridge 2>&1 | grep -i correlat | tail -20
make dead-letters
```

Check what actually arrived from OpenELIS:

```sql
-- make psql-his, on the bridge database
select resource_type, count(*), bool_and(processed)
  from bridge.received_resources group by 1;
```

- No `DiagnosticReport` rows → OpenELIS is not pushing. Confirm
  `org.openelisglobal.fhir.subscriber` in `openelis/generated/common.properties`
  and restart the webapp.
- `DiagnosticReport` present but unprocessed → the `ServiceRequest` chain has not
  arrived. It resolves on a later push; after
  `BRIDGE_RESULT_CORRELATION_RETRY_MINUTES` it is dead-lettered.

### Replaying a dead letter

Dead letters keep their original payload:

```sql
select id, source, reason, payload from bridge.dead_letters order by created_at desc limit 5;
```

Re-publish the payload to its topic to retry:

```bash
echo '<payload json>' | docker exec -i his-kafka \
  /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server kafka:9092 --topic lab.order.created
```

Replay is safe: the bridge claims events by id and derives FHIR resource ids
deterministically from the order id, and the HIS upserts results on the OpenELIS
reference. Re-delivery updates, it does not duplicate.

### Kafka lag

```bash
docker exec his-kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server kafka:9092 --describe --group bridge
```

Consumers commit offsets only after their database write succeeds, so lag after a
crash means redelivery, never loss.

### Kafka is down

Expected behaviour, in order:

- the HIS keeps accepting orders — they commit to `his.outbox` and stay there
- the outbox relay retries, stopping at the first failure so per-order ordering
  holds
- the bridge's consumer stops, does **not** commit offsets, and resumes where it
  was

Nothing to do beyond bringing Kafka back.

```sql
-- make psql-his : how far behind is the outbox?
SELECT count(*) FROM his.outbox WHERE published_at IS NULL;
```

**Confirm the consumer came back with it.** This is the one part that does not
verify itself, because the symptom is silence:

```bash
docker exec his-api curl -s http://127.0.0.1:8080/metrics | grep kafka_consumer_running
```

`1` means subscribed and receiving. `0` means results and status updates are not
reaching the HIS, whatever `/health` says — the service reports healthy because
its HTTP API genuinely is, and Consul keeps it in rotation for exactly that
reason. It retries every 30 seconds and logs `Kafka consumer recovered` when it
succeeds.

This series exists because the first clean run of this stack hit the failure it
detects. `his-api` started before the topics had been created, the subscription
failed, the error was logged once, and boot carried on. Nothing else moved — not
health, not an error rate, and not consumer lag, since a consumer that never
joined its group has no lag to report. Both halves are fixed, but the check is
worth keeping: **alive and consuming are different questions**, and only one of
them is on the health endpoint.

### Consul shows a service as critical

Registered, but Consul cannot reach the address it advertised. Almost always the
address, not the health:

```bash
curl -s localhost:8500/v1/catalog/service/bridge-service | \
  python3 -c "import sys,json; [print(s['ServiceAddress']) for s in json.load(sys.stdin)]"
docker inspect bridge --format '{{range $n,$c := .NetworkSettings.Networks}}{{$n}} {{$c.IPAddress}}{{"\n"}}{{end}}'
```

The advertised address must be the one on **`oe-sandbox-net`**. The bridge sits on
three networks and picks its address from the routing table for exactly this
reason — §10.4. If it advertised a `data` or `integration` address, capture both
outputs and escalate; that is a bug.

A critical service in the catalogue is **worse than an unregistered one**, because
Kong will route to it.

### The FHIR handshake is failing

Symptoms: OpenELIS logs `could not process Task import workflow using remote
address: https://bridge.openelis.org:8443/fhir`, and orders stop being imported.

```bash
docker exec bridge curl -sf http://localhost:8080/metrics | grep bridge_fhir_requests_total
docker logs bridge --since 10m | grep -i "fhir\|handshake"
```

| What you see | What it means |
|---|---|
| `transport="mtls"` climbing | working — the fault is elsewhere, look at OpenELIS's own errors |
| `transport="plaintext"` climbing | something is still using the old `http://bridge:8080/fhir` address |
| neither moving | no connection at all — name resolution or the certificate |

The three things that break it, in order of likelihood:

1. **The CA is not in OpenELIS's truststore.** `make up` imports it, so this means
   the import failed rather than that it was never attempted — check
   `make logs S=oe-trust-bridge`. `make trust-bridge` re-imports and restarts.
   ```bash
   docker exec openelis-webapp keytool -list \
     -keystore /etc/openelis-global/truststore -storepass "$SSL_TRUSTSTORE_PASSWORD" \
     -storetype PKCS12 | grep his-bridge-ca
   ```
2. **The hostname does not match the certificate.** Java verifies the name *after*
   it trusts the chain, so a wrong name fails even with the CA present.
   `BRIDGE_FHIR_BASE` must use `bridge.openelis.org` — a SAN on the bridge's
   certificate, and an alias that exists only on the `integration` network.
3. **OpenELIS's certificate changed** — which in practice means the certgen
   *image* changed, not that time passed. `make up` re-exports the peer
   certificate every time and the bridge re-reads the file on the next
   handshake, so this normally corrects itself; to force it on a running stack,
   `make certs FORCE=true`. No bridge restart is needed — the log says
   `Pinned the FHIR peer to …` when it picks the new one up, and
   `Refused a client certificate` with the thumbprint while it has not.

   > **`certgen` does not generate certificates.** It ships prebuilt keystores
   > baked into the image and copies them into the volumes, so the peer
   > certificate is a fixed property of the pinned digest. Deleting the volumes
   > returns the *same* certificate, byte for byte, and `make certs FORCE=true`
   > rotates our own CA while re-exporting OpenELIS's unchanged. To actually
   > replace it, change the digest in `compose/openelis.yml` and run
   > `make certs-rotate` — see below.

To bisect, turn it off: `BRIDGE_MTLS_ENABLED=false` and
`BRIDGE_FHIR_BASE=http://bridge:8080/fhir`, then `make config` and restart both.
If the fault survives that, it is not TLS.

### Redis is down

Orders and results are unaffected. Redis is consulted only to check whether a
user's session has been revoked, and both services continue without it —
signatures still verified, revocation not enforced.

```bash
docker exec his-api curl -s http://localhost:8080/metrics | grep auth_revocation_checks_total
```

`result="degraded"` climbing means logouts are not taking effect. Fix it the same
day; it is not a middle-of-the-night problem.

**Restarting Redis signs out every user** — sessions are held in memory with no
persistence. Prefer to do that outside clinic hours.

### "Session ended or token revoked" while you were using the browser

**Running a test suite signs you out.** The session in Redis stores the token
itself, so only one token per `usr_id` can be live at a time — minting a second
for the same user silently invalidates the first.

Every suite mints `--user 1` as `suite.runner` through `scripts/lib.sh`. So any
suite will end a browser session created by a plain `make token`, which also
defaults to user 1. The 401 arrives later, on whatever you click next, with
nothing linking it to the suite you ran.

```bash
# if usr_name is suite.runner, that is what happened
docker exec his-redis redis-cli HGET user:1 token | cut -d. -f2 | base64 -d
```

**Browse on a different user id.** The suites own user 1; nothing else does.

```bash
make token USER=42 NAME=dr.demo
```

### The catalogue sync was refused

```
REFUSED: would remove 41% of the menu (guard: 30%)
```

The shrink guard doing its job. A laboratory withdrawing a third of its tests at
once is possible; a partial read that looks like one is far likelier. **Find out
which it is before overriding**, then `make sync-catalogue FORCE=true`.

---

## 8. What to attach when escalating

Anything less will come straight back as a question.

1. `make ps`, and `make logs S=bridge` for the window in question
2. the order number, and its `bridge.order_tracking` row
3. `make export-status` output
4. whether OpenELIS was polling — `docker logs openelis-webapp --since 30m`
5. for a correlation failure, the unprocessed row **including its payload**: what
   OpenELIS actually sent is usually the answer

```sql
SELECT resource_type, resource_id, received_at, jsonb_pretty(content)
FROM bridge.received_resources WHERE NOT processed ORDER BY received_at LIMIT 1;
```

---

## 9. Changing the integration

```bash
make down     # stop applications; databases keep running and keep their data
make clean    # destroy everything, volumes included
```

`make clean` discards both databases. The next `make up` reloads the OpenELIS
schema from scratch (slow) and you must re-run `make sync-catalogue`.

| Change | Files to edit together |
|---|---|
| Add a test | Enable it in OpenELIS (*Administration → Test Management*), give it one LOINC and one specimen, then `make sync-catalogue`. Nothing in this repo lists tests. |
| Change the polled identity | `.env` → `OE_REMOTE_SOURCE_IDENTIFIER`, then `make config` and restart both `bridge` and `openelis-webapp`. **Drain first**: orders already published keep the owner they were written with, so any Task still `requested` under the old value becomes invisible to the poll — the laboratory never receives them, with nothing logged on either side. §7 has the fix. Keep the type `Organization/…`: a `Practitioner/…` owner also becomes the ordering clinician on the accessioning screen, hiding the real one. |
| Change poll or push cadence | `.env` → `OE_REMOTE_POLL_FREQUENCY`, `OE_SUBSCRIBER_BACKUP_INTERVAL`, then `make config` and restart `openelis-webapp` |
| Add an API route | a router under `services/his-api/src/modules/<domain>/routes/`, mounted in `src/app.ts` **and** added to `gateway/kong/kong.yml`. Decide which door it is behind while writing it. |
| Add a configuration setting | `.env.example` **and** `.env` **and** the service's `environment:` block in `compose/`. Missing the third is silent: the service falls back to its compiled-in default and the setting appears to be ignored. |
| Rotate an admin token | `.env` → `BRIDGE_ADMIN_TOKEN` / `HIS_ADMIN_TOKEN`, then restart that service. |
| Rotate `JWT_SECRET` | `.env`, then restart **both** services together. It is a hospital-wide logout, not a rolling change. |
| Rotate `INTERNAL_API_KEY` | `.env`, then restart the bridge **and** the HIS service without a gap: while they disagree, `/internal/*` gets 401 and results stop being written. |
| Require a group for the clinical API | `.env` → `LAB_ORDER_GROUP` / `BRIDGE_OPS_GROUP`. Empty means any authenticated user passes. Tokens minted before the change do not carry the new group — mint again. |
| Raise Kafka durability | `.env` → `KAFKA_REPLICATION_FACTOR=3`, `KAFKA_MIN_INSYNC_REPLICAS=2`, then run three brokers and `docker compose up kafka-init`. `min.insync.replicas` applies with `--alter`; the replication factor of *existing* topics needs a reassignment. |
| Change a retention window | `.env` → `RETENTION_*`, restart `bridge`, then `make prune` to confirm the sweep reports the new window. |

After editing `.env`, always `make config` before restarting OpenELIS —
`common.properties` is a rendered file, not a live environment read.

### Tuning knobs worth knowing at 3am

| Setting | Default | What raising it does |
|---|---|---|
| `BRIDGE_MAX_RETRIES` | 5 | more attempts before a message is dead-lettered |
| `BRIDGE_RESULT_CORRELATION_RETRY_MINUTES` | 15 | longer patience for a report that arrived before its order |
| `BRIDGE_TASK_LEASE_SECONDS` | 90 | longer withholding of a Task already handed over |
| `EXPORT_CHECK_MINUTES` | 5 | less frequent checking of OpenELIS's push channel |
| `EXPORT_STALE_CYCLES` | 5 | more missed pushes tolerated before "stale" |
| `CATALOGUE_MAX_SHRINK` | 0.30 | a larger menu reduction accepted without `FORCE` |
| `RETENTION_*_DAYS` | 14–180 | longer history kept. **`0` disables that sweep** |
| `BRIDGE_MAX_SEARCH_RESULTS` | 200 | a larger cap on `/ops` and FHIR searches |

Each is a restart of one container, not a rebuild.

### Replacing OpenELIS's TLS certificate

The one OpenELIS presents to the bridge, and the one the bridge pins.

```bash
# 1. find what the current certgen image actually carries
docker pull itechuw/certgen:main
docker image inspect itechuw/certgen:main --format '{{index .RepoDigests 0}}'

# 2. pin that digest in compose/openelis.yml (never the :main tag — it moves)
# 3. rotate
make certs-rotate
```

`certs-rotate` stops the stack, removes the three certgen volumes, deletes the
stale exported peer certificate so `init-mtls.sh` re-exports rather than keeping
it, brings everything back, and prints the new validity window. **No patient data
is in those volumes** — they hold the keystore, the truststore and the nginx
certificate and key.

Confirm before trusting it:

```bash
docker exec bridge curl -s http://127.0.0.1:8080/metrics | grep fhir_requests
docker logs bridge 2>&1 | grep -i "Pinned the FHIR peer"
```

`transport="mtls"` climbing and a `Pinned the FHIR peer to …` line with the new
thumbprint means the rotation took. The bridge re-reads the certificate per
handshake, so it needs no restart of its own.

Two things worth knowing:

- **The browser certificate changes too.** OpenELIS's own HTTPS certificate comes
  from the same image, so `https://localhost` will warn afresh. It is self-signed
  either way.
- **Done on 2026-09-15**, moving off a digest whose certificate had expired on
  2026-07-23 — unnoticed for eight weeks, because pinning compares bytes and a
  byte comparison cannot read a date. Full account in
  [security.md §9](security.md#9-what-is-still-open).

### Adding a new FHIR peer

If OpenELIS is deployed under different container names, `/fhir` will refuse it
with 403 and orders will stop. Add the names to `BRIDGE_FHIR_ALLOWED_PEERS` and
restart the bridge. The startup log states what it is enforcing:

```
FHIR endpoint restricted to openelis-webapp, openelis-fhir
```

An empty list disables the check and logs a warning instead — visible, rather
than a silent open door.

### Running the patched OpenELIS build

The stack ships **stock** (`OE_IMAGE_REPO=itechuw`) and there is currently
nothing else to run: **no patches are carried**. The last one was retired on
2026-09-16 after measurement showed the bridge's delivery lease already covered
it, so `make openelis-patched` now refuses with an explanation rather than
building something identical to stock.

What follows is the procedure for a patch that earns its place in future.

```bash
make openelis-patched          # clone the tag, apply patches, build
# then set OE_IMAGE_REPO=his-sandbox in .env
make up
docker ps                      # confirms which build is live
```

Only `openelis-global-2` follows `OE_IMAGE_REPO`. The fhir, frontend, proxy and
database images are pinned to `itechuw` and never patched.

- **The build needs the stack stopped** on an 8 GB host. `make down` first.
- **It retries up to 5 times** (`BUILD_ATTEMPTS`). Truncated downloads from Maven
  Central are common on a slow link; retries resume from the Maven cache.
- **A patch that will not apply stops the build.** That is the process working —
  upstream changed the code it depends on. Read their change; do not force it.
- **Switching back** is the same two lines in reverse. Both directions verified.

Every patch must be re-applied, proven present in the compiled artefact, and
re-validated against the full suite at each upgrade. The procedure — including
how to read the class constant pool to prove the change reached the WAR — is in
[openelis-patches/README.md](../openelis-patches/README.md).

---

## 10. Platform contracts

The sandbox is a reference implementation for the real HIS, which means matching
its **infrastructure contracts** rather than inventing better ones: the same
health document, the same Consul registration, the same metric names, the same
log envelope. A service that is correct but shaped differently teaches the wrong
lesson to whoever copies it, and is invisible to the tooling that has to run it.

The bridge is the interesting one. It is not in the estate's stack and never will
be, so it is the proof that these are **contracts** rather than a shared library:
a service in any language joins the platform by answering the same health
document, registering the same way, exposing the same metric names and writing
the same log envelope.

| Hook | Path / target | Matches |
|---|---|---|
| Health | `GET /health` | `{service, instance, status, timestamp, uptime}` |
| Metrics | `GET /metrics` | `http_requests_total`, `http_request_duration_seconds` |
| Discovery | Consul `agent/service/register` | tags `hospital`, `microservice`, `load-balanced`, `version-x`; 10s/3s check; 30s critical deregistration |
| Logs | Kafka `logs` topic | `{service, level, message, timestamp}` |

`/healthz` is deliberately absent. It was a Kubernetes-ism that nothing in this
estate uses, and having two health paths is how one of them ends up stale.

### 10.1 Health checks the database, not just the process

A service that answers `healthy` while unable to read its own state stays in
Kong's rotation, and every request routed to it fails. `/health` opens a
connection and runs `SELECT 1`; on failure it returns **503** with the reason,
which is what makes Consul mark it critical and take it out of rotation.

### 10.2 A registry outage does not stop the laboratory

The estate's services call `process.exit(1)` if Consul registration fails. Both
services here log the error and carry on.

The reasoning is what each service can still do while unregistered, which in both
cases is everything. The bridge moves patient results: OpenELIS polls it by
hostname and Kafka consults no registry. The HIS service serves every request it
has; only Kong needs the registry to find it, and Kong is one of the callers, not
the work. Refusing to start over a registry outage converts a discovery problem
into a clinical one. This is a genuine divergence from the estate, and a
deliberate one.

### 10.3 Log shipping is filtered, bounded, and never blocks

The `logs` topic is **shared with every service in the estate**, so the question
is not "is this worth logging" but "is this worth putting on everyone's bus".

This was learned expensively. When the bridge was an ASP.NET service it emitted
four Information lines per request — starting, executing, executed, finished —
and with a Consul check every 10s and a Docker healthcheck alongside it, an idle
bridge produced **~2,800 messages in five minutes**, none of them about a
patient. Filtering framework categories to Warning and above took the same idle
window to **21**.

Express logs nothing per request on its own, so the current service needs no
filter — it simply never adds a request logger, and `make smoke` pins that:
sixteen `/health` requests across both services must produce **no more than
eight** lines on the shared topic. Do not reach for morgan.

Two further properties, neither optional:

- **It never blocks a request.** The send is fire and forget: the winston
  transport hands the line to the producer and calls back immediately, so a slow
  broker cannot become a slow API. A failed send is dropped rather than awaited,
  because a logging subsystem that consumes memory until the process dies has
  turned an observability problem into an outage.
- **It never logs.** The obvious implementation publishes through the bridge's
  event publisher, which logs every publish — which publishes, which logs. It
  holds its own producer and reports failures to `stderr`, once per distinct
  reason. Failing in complete silence is how a log pipeline ends up dead for
  months without anyone noticing.

### 10.4 The advertised address comes from the routing table

This one caused a real failure and is worth reading before copying the
implementation anywhere else.

`ConsulRegistration` in the estate's services takes **eth0**. That is correct for
them: each sits on a single Docker network, so it has one address and eth0 is it.

The bridge sits on **three** networks — that multi-homing *is* the architectural
boundary between the HIS estate and OpenELIS. Taking eth0 registered it at its
`oe-data-net` address while Consul watches `oe-sandbox-net`. The service appeared
in the catalogue and every health check failed:

```
bridge-service   172.24.0.4:8080   bridge-service-health=critical
```

A service in the catalogue that Consul cannot reach is **worse** than one that
never registered, because Kong will route to it.

The question is not "what is my address" but "what is my address *from Consul's
side*", and only the routing table can answer it. Opening a socket toward Consul
and reading the local end tells you which address the kernel would use to get
there — `advertisableAddress` in `services/bridge/src/config/consul.ts`:

```ts
const socket = createConnection({ host: config.consul.host, port: config.consul.port });
socket.once('connect', () => done(socket.localAddress ?? null));
socket.once('error', () => done(null));
```

with eth0, then any non-internal IPv4, then the service name as fallbacks.

**This matters for the real HIS too.** The moment any service there joins a
second network, its eth0 registration becomes a coin flip.

### 10.5 Kong routes through Consul

Kong used to address `http://his-api:8080` — a Docker hostname — while the real
platform addresses `<name>.service.consul`.

That difference produced a live fault. Both services were recreated, Docker
reassigned their addresses, and Kong served a request for `/api/health` **from the
bridge**, because it had cached the address that now belonged to the other
container:

```
$ curl localhost:8090/api/health
{"service":"bridge-service", ...}      # expected his-api-service
```

Kong now resolves through Consul, as the HIS platform does:

```yaml
# gateway/kong/kong.yml
- name: his-patient-laborder-service
  protocol: http
  host: his-api-service.service.consul
  port: 8080
```

**Consul needs a fixed address for this**, because Kong's `dns_resolver` takes an
address rather than a name — the same constraint the real HIS solves with its
`CONSUL_HOST` default. So the sandbox network has an explicit subnet
(`SANDBOX_SUBNET`) and Consul has a pinned address in it (`CONSUL_IP`). Nothing
else is pinned; the whole point of registering is that everything else can move.

`A` records only (`KONG_DNS_ORDER: A,CNAME`). Consul answers SRV for these names
too, but its SRV targets point at synthetic `.addr.<dc>.consul` names needing a
second resolution step, and the port is already declared on the service.

**What this buys beyond fixing the stale cache.** Consul only answers with
instances whose health check is passing, so a service that cannot reach its
database drops out of DNS and stops receiving traffic rather than being routed to
and failing every request:

| | |
|---|---|
| `docker stop his-api` | Consul withdrew it in **~5 s** |
| `GET /api/health` | **503**, rather than routing to a dead container |
| `docker start his-api` | back in rotation automatically, Kong untouched |

**Withdrawal is eventual, not instantaneous.** Consul notices within its 10s
check interval, and Kong may serve a cached record for up to `dns_stale_ttl`
after that. Steady state is 503, but during the transition Kong has been observed
returning 500 or 502 while it still holds an address for a container that is
gone. So the test asserts Kong stops returning *success*, not one particular code
at one particular instant — the first version demanded 503 immediately and caught
Kong mid-cache, which was a race in the test rather than a fault in the system.

### 10.6 Two conventions worth copying estate-wide

**Expose the ages, not just the counts.** Request counters answer "is the process
serving". They cannot answer "has anything been stuck since Tuesday" — a queue
with one poisoned item and a queue that is empty produce identical request
metrics. Every alert worth having in this integration reads a gauge measuring how
*old* something is.

**`kafka_consumer_running`.** A service can be up, healthy and passing its Consul
check while its consumer never joined its group — which happened on the first
clean run of this stack, and would have meant no laboratory result was ever
stored again, with nothing anywhere saying so. A consumer that never joined has
no lag, so a lag alert cannot see it.

### What is tested

`make smoke`, in the *Platform integration* section:

- both services are registered in Consul
- **Consul can reach the address each advertised** — the regression test for the
  multi-homing bug above, since registration alone proves nothing
- both carry the estate's tags
- both expose Prometheus request histograms
- application logs arrive on the shared topic in the estate's envelope
- **framework chatter does not** — asserted causally rather than historically: 16
  health requests must add ≤ 8 messages, not the ~64 they produced before the
  filter. Sampling the tail of the topic would have tested what the service did
  last week rather than what it does now.
