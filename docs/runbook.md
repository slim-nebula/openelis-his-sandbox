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
make token       # sign in — the clinical API and the frontend need a user token
```

`make up` is safe to re-run; it is idempotent.

### What happens, in order

| Step | What it does | How long |
|---|---|---|
| `secrets` | First run only: writes `.env` from `.env.example`, generating passwords and tokens | instant |
| `config` | Renders `openelis/generated/common.properties` from `.env` | instant |
| `data-up` | Starts `his-db.external` and `openelis-db.external`, waits for `pg_isready` | 30 s first run, ~4 min for OpenELIS's schema load |
| `app-up` | Builds the HIS service and the bridge, then starts everything else | 3–6 min first run |
| OpenELIS boot | Tomcat, Liquibase migrations, FHIR store startup | 3–8 min under emulation |

The OpenELIS webapp is ready when `docker logs openelis-webapp` shows
`Server startup in [n] milliseconds`. Until then the UI returns 502.

### First-run cost

The upstream OpenELIS images are large and `linux/amd64` only. On Apple
Silicon they are pulled and emulated:

```bash
docker pull --platform linux/amd64 itechuw/openelis-global-2:develop
```

Allocate **at least 8 GB** to Docker Desktop. With less, the OpenELIS webapp
and its HAPI FHIR server compete for heap and the poll loop stalls.

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
docker exec bridge curl -s 'http://localhost:8080/fhir/Task?status=requested&owner=Practitioner/0e11c5a0-0000-4000-a000-000000000001'
```

---

## 3. Test execution

| Phase | Command | Needs a human? |
|---|---|---|
| 1 · platform smoke | `make smoke` | no |
| 2 · order flow | `make e2e` | no, up to LIS acceptance |
| 3 · lab workflow | `make e2e` (second half) | **yes** — release the result in the OpenELIS UI |
| 4 · negative paths | `make negative` | no |

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

The one service written outside the estate's stack, so the people running it
will not be the people who wrote it. **Nothing below requires reading C#.**

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
make ps                    # is it running, and is it healthy?
make logs S=bridge         # what is it saying?
make export-status         # is OpenELIS still pushing results to us? (checks now)
```

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

**Do not put a token on `/fhir`.** OpenELIS 3.2.1.11 cannot send one — the
integration would stop, silently. `docs/security.md` §3 has the evidence.

**Do not reset consumer offsets to unstick a consumer.** That either replays
orders or skips them, depending on the reset policy.

**Do not edit anything in OpenELIS to make the bridge's job easier.** It is the
accredited component. Every asymmetry in this design exists because of that.

---

## 5. Recovery

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
- OpenELIS logs `could not process Task import workflow` → look at the
  exception; usually a resource it tried to dereference was missing.

### An order was rejected

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

1. **The CA is not in OpenELIS's truststore.** After `make clean`, or after
   regenerating certificates. `make trust-bridge` re-imports and restarts.
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
   fresh volume, and the bridge pins the old one. Re-export it:
   `make certs FORCE=true && make trust-bridge`, then restart the bridge.

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
| Change the polled identity | `.env` → `OE_REMOTE_SOURCE_IDENTIFIER`, then `make config` and restart both `bridge` and `openelis-webapp` |
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
