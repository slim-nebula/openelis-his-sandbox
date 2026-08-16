# OpenELIS ↔ HIS Sandbox

A minimal, end-to-end sandbox for integrating **OpenELIS Global 2** with a
microservices HIS. It implements the architecture in
`openelis-sandbox-implementation-brief.md`: a small HIS estate (frontend →
reverse proxy → Kong → Patient + Lab Order microservice), Kafka as the
asynchronous backbone, a **bridge service** that owns all LIS interoperability,
and OpenELIS deployed independently against its own external database.

```
Doctor
  │
  ▼
Frontend ──► Reverse proxy ──► Kong ──► Patient + Lab Order service
                                              │           ▲
                            lab.order.created  │           │ lab.result.released
                                              ▼           │
                                            Kafka ────────┤
                                              │           │
                                              ▼           │
                                          Bridge service ─┘
                                              ▲  │
                          GET /fhir/Task?…    │  │  POST /fhir  (released results)
                                              │  ▼
                                          OpenELIS  ──►  OpenELIS DB (external)
```

Two things make this more than a mock: OpenELIS runs the real upstream
container images, and the bridge speaks the **actual** FHIR integration
protocol OpenELIS implements — no shortcut endpoints, no shared database.

---

## Quick start

Requirements: Docker Desktop with **at least 8 GB** allocated (OpenELIS's own
stack is six containers, all `linux/amd64`, so they run under emulation on
Apple Silicon).

```bash
make up          # render config, start databases, build and start everything
make provision   # stamp LOINC codes onto the OpenELIS test catalogue  ← required
make smoke       # phase 1: platform smoke test          (37 checks)
make e2e         # phase 2/3: place an order and follow it into OpenELIS
make results     # result return: bridge correlation + HIS projection (14 checks)
make negative    # phase 4: negative paths                (16 checks)
```

| Entry point | URL |
|---|---|
| HIS sandbox frontend | http://localhost:8090 |
| HIS API (through Kong) | http://localhost:8090/api/healthz |
| Kong admin | http://localhost:8001 |
| OpenELIS UI | https://localhost/ — `admin` / `adminADMIN!` |
| HIS database | `psql -h localhost -p 55432 -U his_app -d his_sandbox` |
| OpenELIS database | `psql -h localhost -p 15432 -U clinlims -d clinlims` |

`make provision` is not optional. See
[Test identity](#test-identity-the-one-thing-that-must-be-configured).

---

## How the two systems actually talk

This is the part worth reading before changing anything. OpenELIS does not
expose an "import order" API — it **polls** a remote FHIR server and **pushes**
results to a FHIR subscriber. The bridge therefore *is* a FHIR R4 server, and
the whole contract is six HTTP interactions.

### Inbound: order → OpenELIS

Every `org.openelisglobal.remote.poll.frequency` milliseconds, OpenELIS runs:

```
GET  {bridge}/fhir/Task?status=requested&owner={remote.source.identifier}
GET  {bridge}/fhir/ServiceRequest/{id}      ← from Task.basedOn
GET  {bridge}/fhir/Patient/{id}             ← from Task.for
GET  {bridge}/fhir/Practitioner/{id}        ← from ServiceRequest.requester
GET  {bridge}/fhir/Specimen/{id}            ← from ServiceRequest.specimen
PUT  {bridge}/fhir/Task/{id}                → writes back accepted / rejected
```

That `PUT` is how the HIS learns the LIS's verdict: the bridge turns it into a
`lab.order.sent` or `lab.order.failed` event and the order's status in the HIS
moves to `ACCEPTED_BY_LIS` or `REJECTED_BY_LIS`.

Constraints that are easy to get wrong, all learned from the OpenELIS source:

- `Task.owner` must equal `org.openelisglobal.remote.source.identifier`
  **exactly** — it is a string match in the search, not a resolved reference.
  Both come from `OE_REMOTE_SOURCE_IDENTIFIER` in `.env` so they cannot drift.
- **Practitioner ids must be UUIDs.** OpenELIS calls `UUID.fromString()` on
  them while importing, so a readable slug throws and the order is lost.
- `ServiceRequest.code` must carry a `http://loinc.org` coding. It is the only
  thing OpenELIS matches a test on.
- `ServiceRequest.identifier[0].value` becomes the LIS-side external order id,
  and is truncated past 60 characters.

### Outbound: released result → HIS

OpenELIS registers rest-hook `Subscription`s pointing at the bridge and, as a
backstop, pushes every changed resource on a fixed interval
(`OE_SUBSCRIBER_BACKUP_INTERVAL`, in minutes). Both land on the bridge as
`POST /fhir`, `POST /fhir/{type}` or `PUT /fhir/{type}/{id}`.

Correlating a `DiagnosticReport` back to a HIS order takes a walk:

```
DiagnosticReport.basedOn → ServiceRequest (per analysis)
                             └─ .basedOn → ServiceRequest (the one we published)
                                             └─ order_tracking → HIS order number
```

Those resources arrive independently and in no guaranteed order, so
correlation runs on a timer over an inbound mirror table rather than inline on
the HTTP push. A report whose chain has not landed yet is retried; after
`BRIDGE_RESULT_CORRELATION_RETRY_MINUTES` it is dead-lettered.

---

## Test identity: the one thing that must be configured

**In the OpenELIS seed database, no test has a LOINC code.** Without
provisioning, every order the bridge sends is rejected with
`no test found for SR`, and the symptom — a `Task` flipping straight to
`rejected` — looks like a transport failure rather than a mapping gap.

`make provision` stamps six LOINC codes onto the shipped catalogue and refuses
to run if a code would resolve to more than one test:

| HIS `test_code` | LOINC | OpenELIS test |
|---|---|---|
| `HGB` | 718-7 | Hémoglobine (Whole Blood) |
| `GLUC` | 2345-7 | Glucose (Plasma) |
| `CREA` | 2160-0 | Créatinine (Serum) |
| `ALT` | 1742-6 | Transaminases GPT (Serum) |
| `CHOL` | 2093-3 | Cholestérol total (Serum) |
| `PLT` | 777-3 | Plaquette (Whole Blood) |

`his.test_catalogue` and `openelis/provision/01-loinc-mapping.sql` are the two
halves of this contract; change them together. The same edit can be made by
hand in *Administration → Test Management* if you prefer the UI.

---

## Architecture boundaries

The brief's separation rules are enforced by network topology, not convention:

| Network | Members |
|---|---|
| `oe-sandbox-net` | edge proxy, Kong, Kafka, Redis, his-api, bridge, frontend |
| `oe-integration-net` | **bridge and the OpenELIS webapp, nothing else** |
| `oe-internal-net` | OpenELIS webapp, FHIR store, its own UI and proxy |
| `oe-data-net` | the two external database servers |

Consequences you can verify with `docker network inspect`:

- OpenELIS cannot reach Kafka, Kong, or the HIS microservice. Everything
  crosses the bridge.
- Neither database container is on the sandbox network; services reach them
  only via connection strings from `.env`.
- OpenELIS holds no credentials for the HIS database, and vice versa. The
  bridge has its own database again — three separate owners.

The data tier is a **separate compose project** (`compose/data.yml`, project
`his-lab-data`) precisely so it cannot depend on, or be depended on by, the
application stack. On a laptop that is as close to "non-containerised external
database server" as it gets; `make clean` is the only thing that touches its
volumes.

### Data ownership

| Domain | System of record |
|---|---|
| Patient demographics | Patient + Lab Order microservice |
| Lab order request | Patient + Lab Order microservice |
| LIS workflow, accessioning, validation | OpenELIS |
| Detailed lab results | OpenELIS |
| Simplified clinician-facing result copy | HIS sandbox database |

`his.lab_results_summary.openelis_result_ref` is `NOT NULL`: a HIS-side result
can never exist without pointing at the OpenELIS record that owns it. Only
`final`, `amended` and `corrected` reports are forwarded — preliminary values
never leave the lab.

---

## Layout

```
compose/          data.yml (external DBs) · platform.yml · apps.yml · openelis.yml
db/               HIS and bridge schemas, applied on first database start
gateway/          Kong declarative routes · edge nginx config
services/His.Api  Patient + Lab Order microservice (.NET 10)
services/Bridge   Kafka consumer + FHIR R4 server + result correlator (.NET 10)
frontend/         static test client
openelis/         volume assets, common.properties template, LOINC provisioning
scripts/          config rendering and the four test phases
docs/runbook.md   operational runbook
```

---

## API

Client-facing, via `http://localhost:8090/api` (routed by Kong):

| Method | Path |
|---|---|
| `POST` | `/patients` |
| `GET` | `/patients/{id}` |
| `GET` | `/patients/search?q=` |
| `GET` | `/patients/{id}/lab-orders` |
| `GET` | `/patients/{id}/results` |
| `POST` | `/lab-orders` |
| `GET` | `/lab-orders/{id}` |
| `GET` | `/test-catalogue` |

Bridge-facing, **deliberately not routed by Kong** — the bridge reaches
`his-api` directly on the sandbox network, so integration traffic never
transits the public edge:

| Method | Path |
|---|---|
| `GET` | `/internal/patients/{id}` |
| `GET` | `/internal/lab-orders/{id}` |
| `POST` | `/internal/lab-results` |

## Kafka topics

| Topic | Producer | Consumer |
|---|---|---|
| `lab.order.created` | his-api | bridge |
| `lab.order.sent` | bridge | his-api |
| `lab.order.failed` | bridge | his-api |
| `lab.result.released` | bridge | his-api |
| `lab.result.failed` | bridge | monitoring |

Correlation ids are minted by Kong at the edge and carried on the
`X-Correlation-ID` header through HTTP hops and Kafka message headers, so one
id spans a whole order lifecycle.

---

## Configuration

Everything lives in `.env` — endpoints, credentials, topic names, poll
intervals, retry policy. `scripts/render-config.sh` renders OpenELIS's
`common.properties` from it (Tomcat reads that file as a docker secret and
cannot expand environment variables itself) and then asserts that the polled
identifier survived rendering.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Task flips straight to `rejected` | No OpenELIS test carries that LOINC. Run `make provision`. |
| Task stays `requested` forever | OpenELIS cannot reach the bridge, or `Task.owner` ≠ `remote.source.identifier`. Check `docker logs openelis-webapp \| grep -i task`. |
| Order accepted, no result comes back | Result not validated *and released* in OpenELIS, or correlation is still waiting for the ServiceRequest chain. Check `docker logs bridge \| grep -i correlat` and `/ops/dead-letters`. |
| `his-api` restarts at startup | The external HIS database is still initialising; it retries for two minutes. |
| Everything is slow | OpenELIS images are amd64-only and emulated on Apple Silicon. Give Docker more memory. |

Useful:

```bash
make logs S=bridge
make topics
docker exec bridge curl -s http://localhost:8080/ops/orders
docker exec bridge curl -s http://localhost:8080/ops/dead-letters
```

See `docs/runbook.md` for startup, shutdown and recovery procedures.
