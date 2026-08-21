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
```

`make up` is safe to re-run; it is idempotent.

### What happens, in order

| Step | What it does | How long |
|---|---|---|
| `secrets` | First run only: writes `.env` from `.env.example`, generating passwords and tokens | instant |
| `config` | Renders `openelis/generated/common.properties` from `.env` | instant |
| `data-up` | Starts `his-db.external` and `openelis-db.external`, waits for `pg_isready` | 30 s first run, ~4 min for OpenELIS's schema load |
| `app-up` | Builds the two .NET services and starts everything else | 3–6 min first run |
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

## 4. Recovery

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

## 5. Shutdown and reset

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

## 6. Changing the integration

| Change | Files to edit together |
|---|---|
| Add a test | Enable it in OpenELIS (*Administration → Test Management*), give it one LOINC and one specimen, then `make sync-catalogue`. Nothing in this repo lists tests any more. |
| Change the polled identity | `.env` → `OE_REMOTE_SOURCE_IDENTIFIER`, then `make config` and restart both `bridge` and `openelis-webapp` |
| Change poll or push cadence | `.env` → `OE_REMOTE_POLL_FREQUENCY`, `OE_SUBSCRIBER_BACKUP_INTERVAL`, then `make config` and restart `openelis-webapp` |
| Add an API route | `services/His.Api/Program.cs` **and** `gateway/kong/kong.yml` |
| Add a configuration setting | `.env.example` **and** `.env` **and** the service's `environment:` block in `compose/`. Missing the third is silent: the service falls back to its compiled-in default and the setting appears to be ignored. |
| Rotate an admin token | `.env` → `BRIDGE_ADMIN_TOKEN` / `HIS_ADMIN_TOKEN`, then restart that service. There is one token per service, so rotating means a brief window where an in-flight `make sync-catalogue` gets 401 — re-run it. |
| Raise Kafka durability | `.env` → `KAFKA_REPLICATION_FACTOR=3`, `KAFKA_MIN_INSYNC_REPLICAS=2`, then run three brokers and `docker compose up kafka-init`. `min.insync.replicas` is applied with `--alter`, so existing topics pick it up without a rebuild; the replication factor of *existing* topics needs a reassignment. |
| Change a retention window | `.env` → `RETENTION_*`, restart `bridge`, then `make prune` to confirm the sweep reports the new window rather than its default. |

After editing `.env`, always `make config` before restarting OpenELIS —
`common.properties` is a rendered file, not a live environment read.

### Adding a new FHIR peer

If OpenELIS is deployed under different container names, `/fhir` will refuse it
with 403 and orders will stop. Add the names to `BRIDGE_FHIR_ALLOWED_PEERS` and
restart the bridge. The startup log states what it is enforcing:

```
FHIR endpoint restricted to openelis-webapp, openelis-fhir
```

An empty list disables the check and logs a warning instead — visible, rather
than a silent open door.
