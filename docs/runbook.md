# Sandbox runbook

Operational procedures for starting, testing, recovering and tearing down the
OpenELIS ↔ HIS sandbox.

---

## 1. Startup

Order matters: the external database servers must be accepting connections
before the applications start, and OpenELIS's catalogue must be provisioned
before any order will be accepted.

```bash
make up          # renders config → starts databases → builds and starts apps
make sync-catalogue  # read the orderable test menu from OpenELIS into the HIS
make smoke       # confirm the platform before sending clinical data
make token USER=42  # sign in — the suites own user 1, so browse on another id
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
the bridge's own certificate depend on nothing, so they are made before the
stack starts — the bridge serves its FHIR port with one, and OpenELIS's
truststore needs the other imported before Tomcat reads it. OpenELIS's
certificate cannot be made early, because certgen has not created it yet; the
`oe-peer-cert` one-shot exports it from the volume the moment certgen exits, and
the bridge waits for that one-shot before starting.

Get that ordering wrong and a fresh clone comes up with a crashlooping bridge
and an OpenELIS that trusts nobody — which is to say, orders that never reach
the laboratory. It is verified by the only test that counts: `make clean`,
delete `certs/`, `make up`.

The OpenELIS webapp is ready when `docker logs openelis-webapp` shows
`Server startup in [n] milliseconds`. Until then the UI returns 502.

### First-run cost

The upstream OpenELIS images are large and `linux/amd64` only. On Apple
Silicon they are pulled and emulated:

```bash
docker pull --platform linux/amd64 itechuw/openelis-global-2:3.2.2.0
```

Pinned to a **named release**, never `:develop` — see
[openelis-patches/README.md](../openelis-patches/README.md). `OE_VERSION` in
`.env` is the single place it is set.

Allocate **at least 8 GB** to Docker Desktop. With less, the OpenELIS webapp
and its HAPI FHIR server compete for heap and the poll loop stalls. On an 8 GB
host, expect to stop the stack before building anything large — `make
openelis-patched` in particular.

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

---

## 3. Test execution

| Phase | Command | Needs a human? |
|---|---|---|
| 1 · platform smoke | `make smoke` | no |
| 2 · order flow | `make e2e` | no, up to LIS acceptance |
| 3 · lab workflow | `make e2e` (second half) | **yes** — release the result in the OpenELIS UI |
| 4 · negative paths | `make negative` | no |
| 5 · collection workflows | `make collection` | no — both outpatient and inpatient |

`make e2e` runs phases 2 and 3 in one pass: it drives the order into OpenELIS
automatically, then pauses and waits (default 10 minutes) for a lab user to
accession, result, validate and release it. Raise the wait with
`RESULT_TIMEOUT=1800 make e2e`.

Order a different test with `scripts/test-order-flow.sh GLUC`.

### The manual lab steps

1. https://localhost — `admin` / `adminADMIN!`
2. **Order → Incoming Orders**, find the order number, accession it
3. **Work Plan** or **Results Entry** — enter a numeric value
4. **Validation** — validate and release

Release is what matters. The bridge forwards only `final`, `amended` and
`corrected` reports, so an entered-but-unvalidated result stays in the lab.

Latency from release to the HIS frontend is bounded by
`OE_SUBSCRIBER_BACKUP_INTERVAL` (default 1 minute) plus the bridge's 10-second
correlation sweep.

---

## 4. The bridge

The service that joins the two systems, so the people running it may not be
the people who wrote it. **Nothing below requires reading its source.**

It holds no clinical decisions. Everything it does is translation and
bookkeeping: an order becomes a FHIR `Task`, a released report becomes a row the
HIS can display. If it stops, nothing is lost — orders queue in Kafka and results
queue in OpenELIS. **What matters is how long it stops for**, not that it stopped.

### The four things it does on a timer

Knowing these answers most "why has nothing happened yet" questions.

| Worker | Cadence | What it does |
|---|---|---|
| Order consumer | continuous | reads `lab.order.created`, publishes a FHIR Task |
| Result correlator | every **10s**, first run 15s after start | matches pushed results to orders |
| Export monitor | every `EXPORT_CHECK_MINUTES` (**5m**), first run 1m after start | asks OpenELIS whether it is still pushing |
| Retention sweep | every `RETENTION_SWEEP_HOURS` (**24h**), first run 5m after start | deletes aged rows |

OpenELIS polls the bridge on **its own** schedule — `OE_REMOTE_POLL_FREQUENCY`,
default 30s. The bridge cannot make that happen sooner.

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

### Reaching /ops as a person

`/ops/*` takes either the shared operator token or a signed-in HIS user's token.
Prefer the user token: the shared secret then does not have to be passed around,
and the log records **who** ran the request.

```bash
TOKEN=$(scripts/mint-token.sh --quiet --groups lab-orders,lab-ops)
docker exec bridge curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/ops/export-status
```

### The alerts, and what to do about each

Prometheus scrapes the bridge, his-api and Kong every fifteen seconds and
evaluates [`monitoring/alerts.yml`](../monitoring/alerts.yml). There is no
Alertmanager and no pager — routing is a decision about who is on call, which
belongs to the hospital rather than to a sandbox. `make alerts` prints what is
firing; `firing` means the condition has held for the rule's `for:` window,
`pending` means it has just started.

Every rule here covers a **silent** failure. That is the entry requirement: if
it would already show as a 500 or a red container, it does not need an alert.

| Alert | What it means | First move |
|---|---|---|
| `OrderUndelivered` | an order has waited >15 min for the laboratory to collect it | `make export-status`, then `docker logs openelis-webapp`. The order is published and nobody has come for it |
| `LaboratoryStoppedPolling` | no poll for >5 min | OpenELIS is down, or the mTLS handshake is failing — §"The FHIR handshake is failing". Fires *before* `OrderUndelivered` because it does not need an order to exist |
| `DeadLettersGrowing` | new failures in the last hour | `make dead-letters`, then §"Replaying a dead letter" |
| `CatalogueStale` | the test menu is >45 days old | `make sync-catalogue` and **read the diff** |
| `CatalogueNeverSynced` | no menu at all | `make sync-catalogue`. Until it runs, nothing is orderable |
| `ServiceDown` | Prometheus cannot scrape a service | while this fires, every other alert on that service is **blind, not quiet** |
| `ResultConsumerNotRunning` | his-api is up but not consuming | results are piling up on the topic and reaching no patient record. Restart his-api; the consumer retries on its own but a stuck one needs a push |

Two properties of this setup are worth knowing before you trust it:

**A gauge that has never refreshed is absent, not zero.** The bridge publishes
nothing until its first successful database read. This is deliberate and was
learned the hard way — an early version had a query that always threw, so all
four gauges sat at their registered default of `0`, which reads as "nothing
stuck, no dead letters, catalogue fresh". The most alarming possible state
produced the most reassuring possible numbers. An absent metric breaks the alert
expression instead of satisfying it, which is what you want.

**A rule can be healthy and still never fire.** Prometheus reports a rule as
`ok` if it *parses*, whether or not the metric it names exists — so renaming a
gauge silences its alerts permanently behind a green rules page. `make monitoring`
checks that every metric referenced by every alert still resolves to a real
series, which is the only way to catch that.

```bash
make monitoring            # 16 checks: collector, gauges, rules, and the fire path
```

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
in a laboratory: here most orders are placed by test suites and never worked, so
they are accepted and never resulted. In a real deployment that gap is the
backlog, and it should close within a working day for routine tests.

Everything in the report is derived from `order_tracking`, `forwarded_results`
and `dead_letters` at read time. Nothing is written to produce it, which is why
it cannot drift from the data it describes — and why it is worth trusting when
the alerts are quiet.

### Things not to do

**Do not restart the bridge to "clear" a stuck order.** Nothing is held in
memory. The state is in Postgres and Kafka, and a restart replays the same work.

**Do not delete rows from `bridge.fhir_resources`.** It is what OpenELIS
*reads* — an order it has not polled yet, a ServiceRequest it dereferences when a
late report arrives. It is deliberately excluded from the retention sweep for
this reason.

**Do not set `BRIDGE_FHIR_ALLOWED_PEERS` to empty to fix a 403.** That opens the
result-injection path to everything on the network. See §8, *Adding a new FHIR
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
would stop, silently. Confirmed on 3.2.1.11 and unchanged in 3.2.2.0.
`docs/security.md` §3 has the evidence.

**Do not reset consumer offsets to unstick a consumer.** That either replays
orders or skips them, depending on the reset policy.

**Do not edit anything in OpenELIS to make the bridge's job easier.** It is the
accredited component. Every asymmetry in this design exists because of that.

---

## 5. Recovery

### An order is sitting at `AWAITING_COLLECTION`

**Check this first, and do not escalate it as an integration fault.** It is the
one state in which nothing has been sent to the laboratory — no outbox row, no
Kafka event, no FHIR Task. Every other stalled state means a system did not do
its job. This one means **a specimen has not been drawn**, and no amount of
restarting anything will move it.

```bash
make psql-his
```
```sql
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
`CREATED` without an outbox row produces an order that will never be sent and
now looks dispatched — strictly worse than the state you started in. Writing the
outbox row without a collection time sends the laboratory an order whose whole
reason for waiting has been lost. They commit together for exactly this reason.

An order that has been waiting for hours is usually a ward-process question —
was the blood drawn and nobody recorded it? — not a system one. There is
deliberately **no automatic timeout**: expiring a real pending order because a
nurse was busy would be worse than leaving it visible.

### One order is stuck at `SENT_TO_LIS` and the others are fine — check the patient's NAME

**OpenELIS rejects patient names containing digits**, and the failure is silent
from our side. Found the hard way: a test fixture named `Probe233437` produced

```
Validation failed for classes [org.openelisglobal.person.valueholder.Person]
'invalid name format, possibly illegal character', propertyPath=lastName
```

and then, every 30 seconds, forever:

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

A hit means a patient name in that order contains a character OpenELIS's
`Person` validator refuses — a digit is the one confirmed here. The fix is in
the patient record, not the integration: correct the name in the HIS and place
a new order. The stuck Task will keep retrying until OpenELIS is restarted or
the resource is removed.

Worth designing around in a real HIS: placeholder names for unidentified
patients (`Unknown 47`, `Baby of Ward 3`), house numbers accidentally typed into
a name field, and some transliterations will all trip this.

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
- **Task present, OpenELIS reachable, and the poll returns `0 match(es)`** →
  the two sides disagree about the laboratory's address. This is silent on both
  sides: the bridge answers correctly, OpenELIS asks correctly, and the answer
  is legitimately empty.

  ```bash
  # What OpenELIS is asking for — the RUNNING value, which a container started
  # before the last `make config` will not have.
  docker exec openelis-webapp grep remote.source.identifier /run/secrets/common.properties
  # What the bridge is stamping, and on how many undelivered orders.
  docker exec bridge curl -s "http://127.0.0.1:8080/fhir/Task?status=requested" \
    | grep -o '"reference":"[^"]*"' | sort | uniq -c
  ```

  If they differ, the usual cause is a changed `OE_REMOTE_SOURCE_IDENTIFIER`
  with undelivered orders left behind. Move them onto the current address —
  bridge-side resources only, nothing inside OpenELIS changes:

  ```sql
  -- make psql-his, on the bridge database
  UPDATE bridge.fhir_resources
     SET content = jsonb_set(content, '{owner,reference}', '"Organization/<current-uuid>"')
   WHERE resource_type = 'Task' AND content ->> 'status' = 'requested';
  ```
- OpenELIS logs `could not process Task import workflow` → look at the
  exception; usually a resource it tried to dereference was missing.

**If OpenELIS logs the same failed import over and over, that is the known
upstream defect and it will not stop on its own.** A Task whose import throws is
never acknowledged, so it stays `status=requested` and the next poll picks it up
again — one clean rebuild left a single order being re-imported every 30 seconds
for twenty-six minutes, and one of those passes created a **duplicate patient
record**. Full evidence: [data-flow.md §6](data-flow.md#6-where-the-test-menu-comes-from).

```bash
# Is this happening? A count that keeps climbing for one Task is the signature.
docker logs openelis-webapp --since 10m 2>&1 | grep -c "could not process Task"
# Which orders is the bridge still offering?
docker exec bridge curl -s "http://127.0.0.1:8080/fhir/Task?status=requested&owner=$OE_REMOTE_SOURCE_IDENTIFIER"
```

To stop the loop, take the order out of the poll's result set — the Task is the
bridge's own resource, so this changes nothing inside OpenELIS:

```sql
-- make psql-his, on the bridge database
UPDATE bridge.order_tracking SET task_status = 'failed', last_error = 'import loop, see runbook'
 WHERE order_number = 'LAB-...';
```

Then check `clinlims.patient` for duplicates created by the retries, and tell
the laboratory: merging patient records is theirs to do, not ours.

**What the bridge now does about it.** A Task handed to the laboratory is
withheld from the next polls for `BRIDGE_TASK_LEASE_SECONDS` (90 by default), so
OpenELIS cannot be given the same order twice at once. That removes the
collision — the 409 and the duplicate patient both need two overlapping imports
— without touching the Task, which stays `requested` and stays readable by id.

`deliveries` is the attempt counter OpenELIS does not keep. It is the fastest
way to tell a slow laboratory from a failing import:

```sql
-- make psql-his, on the bridge database
SELECT l.resource_id, l.deliveries, l.first_at, l.last_at, t.order_number
  FROM bridge.delivery_leases l
  LEFT JOIN bridge.order_tracking t ON t.fhir_task_id = l.resource_id
 WHERE l.deliveries > 1 ORDER BY l.deliveries DESC;
```

One delivery is normal. A number climbing steadily means the laboratory takes
the order and never returns a verdict — look at `openelis-webapp`'s log for the
import exception. The bridge also logs a warning on every re-delivery.

> **Still an open decision.** The lease stops orders colliding; it does not stop
> them being retried for ever. A mediator arguably also owes the HIS a delivery
> timeout — after N attempts, give up, publish `lab.order.failed`, stop offering
> the Task. That is deliberately **not** built: abandoning a clinician's order
> automatically is a clinical safety decision, not one to make on the sandbox's
> own authority. `deliveries` gives you the number to set the threshold from
> when you decide. Raise it before building it.

### An order was rejected

**First: `rejected` does not reliably mean the laboratory refused it.** Check
whether OpenELIS actually recorded a refusal before treating it as one — a
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
make sync-catalogue     # re-read it from OpenELIS
```

If a test you expect is missing, OpenELIS considers it ambiguous. Check why:

```bash
docker logs bridge --since 10m | grep -E 'is claimed by|OpenELIS catalogue:'
```

The sync logs each collision by name and a one-line summary of what it filtered
and why. A test is offered only if it is active, orderable, holds exactly one
LOINC and accepts exactly one specimen. Resolve it in OpenELIS under
*Administration → Test Management*, then sync again.

### A released result never arrives

```bash
docker logs bridge 2>&1 | grep -i correlat | tail -20
docker exec bridge curl -s -H "Authorization: Bearer $BRIDGE_ADMIN_TOKEN" \
  http://localhost:8080/ops/dead-letters
```

Check what actually arrived from OpenELIS:

```bash
docker exec -e PGPASSWORD=bridge_app_pw his-db-external \
  psql -U bridge_app -d bridge_sandbox \
  -c "select resource_type, count(*), bool_and(processed) from bridge.received_resources group by 1;"
```

- No `DiagnosticReport` rows → OpenELIS is not pushing. Confirm
  `org.openelisglobal.fhir.subscriber` in
  `openelis/generated/common.properties` and restart the webapp.
- `DiagnosticReport` present but unprocessed → the `ServiceRequest` chain has
  not arrived. It resolves on a later push; after
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
deterministically from the order id, and the HIS upserts results on the
OpenELIS reference. Re-delivery updates, it does not duplicate.

### Kafka lag

```bash
docker exec his-kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server kafka:9092 --describe --group bridge
```

Consumers commit offsets only after their database write succeeds, so lag
after a crash means redelivery, never loss.

---

### Consul shows a service as critical

Registered, but Consul cannot reach the address it advertised. Almost always the
address, not the health:

```bash
curl -s localhost:8500/v1/catalog/service/bridge-service | \
  python3 -c "import sys,json; [print(s['ServiceAddress']) for s in json.load(sys.stdin)]"
docker inspect bridge --format '{{range $n,$c := .NetworkSettings.Networks}}{{$n}} {{$c.IPAddress}}{{"\n"}}{{end}}'
```

The advertised address must be the one on **`oe-sandbox-net`**. The bridge sits
on three networks and picks its address from the routing table for exactly this
reason (`docs/platform-integration.md` §4). If it advertised a `data` or
`integration` address, capture both outputs and escalate — that is a bug.

A critical service in the catalogue is **worse than an unregistered one**,
because Kong will route to it.

### The FHIR handshake is failing

Symptoms: OpenELIS logs `could not process Task import workflow using remote
address: https://bridge.openelis.org:8443/fhir`, and orders stop being imported.

```bash
# Is the listener up, and is anything getting through?
docker exec bridge curl -sf http://localhost:8080/metrics | grep bridge_fhir_requests_total
docker logs bridge --since 10m | grep -i "fhir\|handshake"
```

| What you see | What it means |
|---|---|
| `transport="mtls"` climbing | working — the fault is elsewhere, look at OpenELIS's own errors |
| `transport="plaintext"` climbing | something is still using the old `http://bridge:8080/fhir` address |
| neither moving | no connection is being made at all — name resolution or the certificate |

The three things that break it, in order of likelihood:

1. **The CA is not in OpenELIS's truststore.** `make up` imports it, so this
   means the import failed rather than that it was never attempted — check
   `make logs S=oe-trust-bridge`. `make trust-bridge` re-imports and restarts.
   ```bash
   docker exec openelis-webapp keytool -list \
     -keystore /etc/openelis-global/truststore -storepass "$SSL_TRUSTSTORE_PASSWORD" \
     -storetype PKCS12 | grep his-bridge-ca
   ```
2. **The hostname does not match the certificate.** Java verifies the name
   *after* it trusts the chain, so a wrong name fails even with the CA present.
   `BRIDGE_FHIR_BASE` must use `bridge.openelis.org` — a SAN on the bridge's
   certificate, and an alias that exists only on the `integration` network.
3. **OpenELIS's certificate changed.** certgen regenerates the keystore on a
   fresh volume, and the bridge pins the old one. `make up` re-exports it every
   time and the bridge re-reads the file on the next handshake, so this normally
   corrects itself; to force it on a running stack, `make certs FORCE=true`. No
   bridge restart is needed — the log says `Pinned the FHIR peer to …` when it
   picks the new one up, and `Refused a client certificate` with the thumbprint
   while it has not.

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

`result="degraded"` climbing means logouts are not taking effect. Fix it the
same day; it is not a middle-of-the-night problem.

**Restarting Redis signs out every user** — sessions are held in memory with no
persistence. Prefer to do that outside clinic hours. Afterwards, everyone
including `make token` must sign in again.

### "Session ended or token revoked" while you were using the browser

**Running a test suite signs you out.** The session in Redis stores the token
itself, so only one token per `usr_id` can be live at a time — minting a second
for the same user silently invalidates the first.

Every suite mints `--user 1` as `suite.runner` through `scripts/lib.sh`. So
`make auth`, `make smoke` or any other suite will end a browser session created
by a plain `make token`, which also defaults to user 1. The 401 arrives later,
on whatever you click next, with nothing linking it to the suite you ran.

Confirm it in one command — if `usr_name` is `suite.runner`, that is what
happened:

```bash
docker exec his-redis redis-cli HGET user:1 token | cut -d. -f2 | base64 -d
```

**Browse on a different user id.** The suites own user 1; nothing else does.

```bash
make token USER=42 NAME=dr.demo
```

Then tests and a browser session coexist. Note this needs the `$(origin USER)`
handling in the `token` target — before that fix, `USER=` on the command line
was indistinguishable from the shell's own `USER` and could not be used.

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
succeeds; if it stays at 0, the log line says why.

This series exists because the first clean run of this stack hit the failure it
detects. `his-api` started before the topics had been created, the subscription
failed, the error was logged once, and boot carried on. Nothing else moved — not
health, not an error rate, and not consumer lag, since a consumer that never
joined its group has no lag to report. Both halves are fixed (the service now
waits for `kafka-init` and retries for ever), but the check is worth keeping:
**alive and consuming are different questions**, and only one of them is on the
health endpoint.

### The catalogue sync was refused

```
REFUSED: would remove 41% of the menu (guard: 30%)
```

The shrink guard doing its job. A laboratory withdrawing a third of its tests at
once is possible; a partial read that looks like one is far likelier. **Find out
which it is before overriding**, then `make sync-catalogue FORCE=true`.

---

## 6. What to attach when escalating

Anything less will come straight back as a question.

1. `make ps`, and `make logs S=bridge` for the window in question
2. the order number, and its `bridge.order_tracking` row
3. `make export-status` output
4. whether OpenELIS was polling — `docker logs openelis-webapp --since 30m`
5. for a correlation failure, the unprocessed row **including its payload**:
   what OpenELIS actually sent is usually the answer

```sql
SELECT resource_type, resource_id, received_at, jsonb_pretty(content)
FROM bridge.received_resources WHERE NOT processed ORDER BY received_at LIMIT 1;
```

---

## 7. Shutdown and reset

```bash
make down     # stop applications; databases keep running and keep their data
make clean    # destroy everything, volumes included
```

`make clean` discards both databases. The next `make up` reloads the OpenELIS
schema from scratch (slow) and you must re-run `make sync-catalogue`, or the HIS
will have no test menu.

To reset only the HIS side and leave OpenELIS's data alone:

```bash
docker compose -p his-lab-sandbox --env-file .env \
  -f compose/platform.yml -f compose/apps.yml -f compose/openelis.yml down
docker exec -e PGPASSWORD=postgres_admin_pw his-db-external \
  psql -U postgres -c "drop database his_sandbox; drop database bridge_sandbox;"
docker compose -p his-lab-data --env-file .env -f compose/data.yml restart his-db
```

---

## 8. Changing the integration

| Change | Files to edit together |
|---|---|
| Add a test | Enable it in OpenELIS (*Administration → Test Management*), give it one LOINC and one specimen, then `make sync-catalogue`. Nothing in this repo lists tests any more. |
| Change the polled identity | `.env` → `OE_REMOTE_SOURCE_IDENTIFIER`, then `make config` and restart both `bridge` and `openelis-webapp`. **Drain first**: orders already published keep the owner they were written with, so any Task still `requested` under the old value becomes invisible to the poll — the laboratory simply never receives them, with nothing logged on either side. §5 has the query and the fix. Keep the type `Organization/…`: a `Practitioner/…` owner also becomes the ordering clinician on the accessioning screen, hiding the real one. |
| Change poll or push cadence | `.env` → `OE_REMOTE_POLL_FREQUENCY`, `OE_SUBSCRIBER_BACKUP_INTERVAL`, then `make config` and restart `openelis-webapp` |
| Add an API route | a router under `services/his-api/src/modules/<domain>/routes/`, mounted in `src/app.ts` **and** added to `gateway/kong/kong.yml`. Decide which door it is behind while writing it: user token, service key, or operator token |
| Add a configuration setting | `.env.example` **and** `.env` **and** the service's `environment:` block in `compose/`. Missing the third is silent: the service falls back to its compiled-in default and the setting appears to be ignored. |
| Rotate an admin token | `.env` → `BRIDGE_ADMIN_TOKEN` / `HIS_ADMIN_TOKEN`, then restart that service. There is one token per service, so rotating means a brief window where an in-flight `make sync-catalogue` gets 401 — re-run it. |
| Rotate `JWT_SECRET` | `.env`, then restart **both** services together. Every token in circulation stops working at that moment and everyone signs in again — it is a hospital-wide logout, not a rolling change. |
| Rotate `INTERNAL_API_KEY` | `.env`, then restart the bridge **and** the HIS service. Restart them in either order but without a gap: while they disagree, the bridge's calls to `/internal/*` get 401 and results stop being written to the HIS. |
| Require a group for the clinical API | `.env` → `LAB_ORDER_GROUP` / `BRIDGE_OPS_GROUP` to an IAM group name, restart that service. Empty means any authenticated user passes. Tokens minted before the change do not carry the new group — mint again. |
| Raise Kafka durability | `.env` → `KAFKA_REPLICATION_FACTOR=3`, `KAFKA_MIN_INSYNC_REPLICAS=2`, then run three brokers and `docker compose up kafka-init`. `min.insync.replicas` is applied with `--alter`, so existing topics pick it up without a rebuild; the replication factor of *existing* topics needs a reassignment. |
| Change a retention window | `.env` → `RETENTION_*`, restart `bridge`, then `make prune` to confirm the sweep reports the new window rather than its default. |

After editing `.env`, always `make config` before restarting OpenELIS —
`common.properties` is a rendered file, not a live environment read.

### Running the patched OpenELIS build

The stack ships **stock** (`OE_IMAGE_REPO=itechuw`) and should stay that way
unless you have a reason. To switch:

```bash
make openelis-patched          # clone the tag, apply patches, build
# then set OE_IMAGE_REPO=his-sandbox in .env
make up
docker ps                      # confirms which build is live
```

Only `openelis-global-2` follows `OE_IMAGE_REPO`. The fhir, frontend, proxy and
database images are pinned to `itechuw` and never patched.

Four things worth knowing before you do this:

- **The build needs the stack stopped** on an 8 GB host. `make down` first.
- **It retries up to 5 times** (`BUILD_ATTEMPTS`). Truncated downloads from Maven
  Central are common on a slow link; retries resume from the Maven cache rather
  than restarting, because a BuildKit cache mount survives a failed step.
- **A patch that will not apply stops the build.** That is the process working —
  upstream changed the code it depends on. Read their change; do not force it.
- **Switching back** is the same two lines in reverse. Both directions are
  verified.

Every patch must be re-applied, proven present in the compiled artefact, and
re-validated against the full suite at each upgrade. The procedure — including
how to read the class constant pool to prove the change reached the WAR — is in
[openelis-patches/README.md](../openelis-patches/README.md).

### Tuning knobs worth knowing at 3am

| Setting | Default | What raising it does |
|---|---|---|
| `BRIDGE_MAX_RETRIES` | 5 | more attempts before a message is dead-lettered |
| `BRIDGE_RESULT_CORRELATION_RETRY_MINUTES` | 15 | longer patience for a report that arrived before its order |
| `EXPORT_CHECK_MINUTES` | 5 | less frequent checking of OpenELIS's push channel |
| `EXPORT_STALE_CYCLES` | 5 | more missed pushes tolerated before "stale" |
| `CATALOGUE_MAX_SHRINK` | 0.30 | a larger menu reduction accepted without `FORCE` |
| `RETENTION_*_DAYS` | 14–180 | longer history kept. **`0` disables that sweep** |
| `BRIDGE_MAX_SEARCH_RESULTS` | 200 | a larger cap on `/ops` and FHIR searches |

Each is a restart of one container, not a rebuild.

### Adding a new FHIR peer

If OpenELIS is deployed under different container names, `/fhir` will refuse it
with 403 and orders will stop. Add the names to `BRIDGE_FHIR_ALLOWED_PEERS` and
restart the bridge. The startup log states what it is enforcing:

```
FHIR endpoint restricted to openelis-webapp, openelis-fhir
```

An empty list disables the check and logs a warning instead — visible, rather
than a silent open door.
