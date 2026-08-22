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
make secrets     # generate .env from .env.example        ← first run only
make up          # render config, start databases, build and start everything
make sync-catalogue  # read the orderable test menu from OpenELIS  ← required
make migrate     # apply any new schema migrations to a running database
make smoke       # phase 1: platform smoke test          (51 checks)
make e2e         # phase 2/3: place an order and follow it into OpenELIS
make results     # result return: bridge correlation + HIS projection (14 checks)
make negative    # phase 4: negative paths and access control (34 checks)
make rejection   # LIS rejection round trip               (14 checks)
make corrections # corrections and retractions            (11 checks)
make catalogue-test  # catalogue discovery, filters and guards (19 checks)
make capture     # capture what OpenELIS really sends on release
make prune       # run the retention sweep now
```

`make secrets` writes `.env` (gitignored, mode 600) from `.env.example`,
generating the passwords and tokens. It then prints the two values it cannot
invent — OpenELIS's own admin password and the service account the bridge reads
the catalogue with — because those belong to OpenELIS, not to this repository.
It refuses to overwrite an existing `.env`: regenerating passwords against
databases initialised with the old ones does not rotate anything, it locks you
out.

| Entry point | URL |
|---|---|
| HIS sandbox frontend | http://localhost:8090 |
| HIS API (through Kong) | http://localhost:8090/api/health |
| Consul UI | http://localhost:8500 |
| Kong admin | http://localhost:8001 |
| OpenELIS UI | https://localhost/ — `admin` / `adminADMIN!` |
| HIS database | `psql -h localhost -p 55432 -U his_app -d his_sandbox` |
| OpenELIS database | `psql -h localhost -p 15432 -U clinlims -d clinlims` |

`make sync-catalogue` is not optional — without it the HIS has no test menu. See
[Test identity](#test-identity-how-the-two-systems-agree-on-a-test).

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
- **`ServiceRequest.id` must equal that same identifier.** OpenELIS's Incoming
  Orders view reads `ServiceRequest/{electronic_order.external_id}` straight
  out of its local FHIR store. Give the resource a different id — a UUID, say —
  and ordering still works, but every order shows the lab
  `error in data collection - FHIR resource not found` and no test name. It is
  invisible from the integration's side and obvious from the lab's.

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

## Test identity: how the two systems agree on a test

Neither system sends its own internal identifier. OpenELIS's `testId` means
nothing outside that installation and the HIS `test_code` means nothing outside
the HIS, so the wire contract is **LOINC**, which means the same thing
everywhere.

The HIS no longer keeps a hand-written list of tests. The bridge asks OpenELIS
which tests it will actually accept an order for, and the HIS mirrors the answer:

```bash
make sync-catalogue   # read the menu from OpenELIS, mirror it into the HIS
make catalogue        # show what is currently orderable
```

A test is offered only if OpenELIS reports it **active**, **orderable**, holding
**exactly one LOINC**, and bound to **exactly one specimen** — and only if no
other test claims that LOINC. Of 210 tests in the shipped catalogue, 25 qualify.

That filtering is not fussiness. OpenELIS matches an incoming order on the LOINC
code alone; it will not choose between two tests sharing a code, and it will not
use the `Specimen` we send to narrow a multi-specimen test. An ambiguous order is
accepted into the queue and then stalls at the accessioning screen waiting for a
human to pick the test. Not offering it is the honest outcome.

**Sync is manual**, because a clinic changes its menu when it commissions an
analyser — a few times a year. The technician who enables the test in OpenELIS
presses the button and reads the diff. See
[the operational procedure](docs/catalogue-discovery-plan.md).

To make a currently-ambiguous test orderable, resolve it in OpenELIS under
*Administration → Test Management* — one LOINC, one specimen — then sync. That
decision belongs to the laboratory, which is why the integration no longer
edits OpenELIS's catalogue to force it.


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

Administrative, requiring `Authorization: Bearer $HIS_ADMIN_TOKEN`:

| Method | Path |
|---|---|
| `POST` | `/admin/catalogue/refresh` |

On the bridge, requiring `Authorization: Bearer $BRIDGE_ADMIN_TOKEN`:

| Method | Path | |
|---|---|---|
| `POST` | `/catalogue/sync` | replace the menu from OpenELIS |
| `GET` | `/catalogue/syncs` | sync history |
| `GET` | `/ops/orders` | what is published for OpenELIS to poll |
| `GET` | `/ops/dead-letters` | what could not be handled |
| `GET` | `/ops/export-status` | is OpenELIS still pushing results |
| `POST` | `/ops/export-status/check` | ask now rather than wait for the cycle |
| `POST` | `/ops/retention/sweep` | prune now |

Unauthenticated on the bridge, and deliberately so: `GET /healthz` and
`GET /catalogue`. Both are read-only, and locking the ordering screen out of
its own test menu is a worse failure than leaving the menu readable.

`/fhir` is restricted by **origin**, not by token — OpenELIS 3.2.1.11 cannot
present a credential to a remote FHIR source. The evidence and the consequences
are in [`docs/security.md`](docs/security.md#3-why-the-fhir-endpoint-has-no-token).

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
intervals, retry policy, retention windows. `scripts/render-config.sh` renders
OpenELIS's `common.properties` from it (Tomcat reads that file as a docker
secret and cannot expand environment variables itself) and then asserts that
the polled identifier survived rendering.

`.env` is **not committed**. `.env.example` holds the shape of the
configuration and is; `make secrets` turns one into the other. Adding a setting
means adding it to the example; adding a secret means adding it as
`__GENERATE__` and getting a fresh one for free.

Security posture — what is protected, what is not, and why the FHIR endpoint
cannot use a token — is in [`docs/security.md`](docs/security.md).

## Platform integration

Both services present the same four hooks the real HIS platform expects, in the
same shapes its Node services use: `GET /health`, `GET /metrics`, Consul
self-registration, and application logs on the shared Kafka `logs` topic. The
sandbox runs its own Consul so that registration path is exercised rather than
assumed.

The reasoning — including why a registry outage must not stop the laboratory,
why log shipping is filtered and bounded, and why the advertised address comes
from the routing table rather than `eth0` — is in
[`docs/platform-integration.md`](docs/platform-integration.md).

## Troubleshooting

| Symptom | Cause |
|---|---|
| Task flips straight to `rejected` | The LOINC no longer resolves to one OpenELIS test. Re-run `make sync-catalogue`; if it is still offered, the laboratory has changed that test. |
| Task stays `requested` forever | OpenELIS cannot reach the bridge, or `Task.owner` ≠ `remote.source.identifier`. Check `docker logs openelis-webapp \| grep -i task`. |
| Order accepted, no result comes back | Result not validated *and released* in OpenELIS, or correlation is still waiting for the ServiceRequest chain. Check `docker logs bridge \| grep -i correlat` and `/ops/dead-letters`. |
| `401` from `/ops/*` or a sync | Missing or wrong bearer token. `make` targets pass it for you; a hand-written curl needs `-H "Authorization: Bearer $BRIDGE_ADMIN_TOKEN"`. |
| `503` from an admin endpoint | The token is not *configured*. These fail closed, so an unset variable refuses everything rather than opening the door. Check the service's `environment:` block in `compose/apps.yml`. |
| `403` from `/fhir`, orders stop | The caller is not in `BRIDGE_FHIR_ALLOWED_PEERS`. Expected if OpenELIS was renamed or redeployed under different container names — see `docs/runbook.md` → Adding a new FHIR peer. |
| `his-api` restarts at startup | The external HIS database is still initialising; it retries for two minutes. |
| Everything is slow | OpenELIS images are amd64-only and emulated on Apple Silicon. Give Docker more memory. |

Useful:

```bash
make logs S=bridge
make topics
make export-status                 # is OpenELIS still pushing results to us
make prune                         # run the retention sweep and see what went
docker exec bridge curl -s -H "Authorization: Bearer $BRIDGE_ADMIN_TOKEN" \
  http://localhost:8080/ops/orders
docker exec bridge curl -s -H "Authorization: Bearer $BRIDGE_ADMIN_TOKEN" \
  http://localhost:8080/ops/dead-letters
```

See `docs/runbook.md` for startup, shutdown and recovery procedures.
