# Acceptance criteria — how each one is verified

Every criterion in the brief, mapped to the automated check that proves it.

```bash
make smoke      # 37 checks
make e2e        # order flow into OpenELIS (pauses for the manual lab step)
make results    # 14 checks
make negative   # 16 checks
```

All four suites were run against the real stack: OpenELIS Global 2 on the
upstream `develop` images, against its own external database.

| # | Criterion | Verified by | Check |
|---|---|---|---|
| 1 | A user can create a patient from the frontend | `make e2e` §1 | `POST /api/patients` through proxy → Kong → his-api, then row asserted in `his.patients` |
| 2 | A user can place a lab order from the frontend | `make e2e` §2 | `POST /api/lab-orders` returns an order number |
| 3 | The order is persisted in the HIS sandbox database | `make e2e` §2 | row in `his.lab_orders` + audit row in `his.lab_order_events` |
| 4 | The order event is published to Kafka | `make e2e` §3 | order number found on the `lab.order.created` topic |
| 5 | The bridge consumes the order and creates the matching order in OpenELIS | `make e2e` §4–5 | `bridge.order_tracking` row; Task returned by the exact poll query; `clinlims.electronic_order` row with our `external_id`; Task status → `accepted` |
| 6 | A lab user can process and release the result in OpenELIS | `make e2e` §6 | manual step in the OpenELIS UI, then polled — see the note below |
| 7 | The released result is returned through the bridge and stored as a simplified result | `make results` | correlation walk resolves the report to the order; row in `his.lab_results_summary`; order status → `RESULT_AVAILABLE` |
| 8 | The frontend can display the simplified result | `make results` | `GET /api/patients/{id}/results` returns the result through the gateway |
| 9 | No direct database coupling between OpenELIS and the HIS sandbox | `make smoke` | no database container on the sandbox network; the bridge's credentials are refused by the HIS database (`CONNECT` denied); OpenELIS holds no HIS credentials at all |
| 10 | OpenELIS runs containerised while its database is externalised | `make smoke` | `datasource.url` on the running webapp points at `openelis-db.external`, which lives in a separate compose project and network |

## Non-functional requirements

| Requirement | Where it lives |
|---|---|
| Clear service boundaries | Network topology in `compose/platform.yml`; the bridge is the only member of both `sandbox` and `integration` |
| Containerised apps, external databases | `compose/data.yml` is a separate project; nothing else mounts its volumes |
| Externalised configuration | `.env` is the only source; `scripts/render-config.sh` renders what cannot read env vars |
| Structured logging | JSON console logging in both .NET services; JSON access log on the edge proxy |
| Correlation ID propagation | Minted by Kong's `correlation-id` plugin, carried on `X-Correlation-ID` across HTTP hops and as a Kafka message header |
| Retry and dead-letter handling | Exponential backoff on HIS fetches; uncommitted offsets on handler failure; `bridge.dead_letters` + `/ops/dead-letters` |
| Idempotent result ingestion | `bridge.processed_events`, `bridge.forwarded_results`, and `UNIQUE (openelis_result_ref)` on `his.lab_results_summary` |

## What "verified" means for criterion 6

The outbound channel is proven live, not assumed: OpenELIS registered 8 FHIR
`Subscription` resources pointing at the bridge, its `data_export_task` row
targets `http://bridge:8080/fhir`, and the bridge has received real
`Patient` / `ServiceRequest` / `Specimen` / `Task` / `Practitioner` /
`Organization` resources pushed by OpenELIS during ordinary operation.

`DiagnosticReport` and `Observation` only exist once a lab user validates and
releases a result, so `make results` delivers those two through the bridge's
real FHIR endpoint over the same rest-hook mechanism, shaped exactly as
OpenELIS shapes them (verified against the `ServiceRequest` resources OpenELIS
actually pushed, which carry both our order-number identifier and OpenELIS's
own remote-reference identifier). That exercises the correlation walk, the
projection and the idempotency guards. The one step no script performs is a
human clicking through the OpenELIS validation screen.

## Negative paths (`make negative`)

| Scenario | Expected behaviour |
|---|---|
| Invalid patient ID | 400, no order row created |
| Invalid test code mapping | 400, no order row created |
| Duplicate event delivery | Event key claimed once; no extra FHIR Task, one tracking row |
| Replayed result message | Three deliveries → exactly one row (upsert on the OpenELIS reference) |
| Result for an unknown order | Logged and ignored, never stored |
| OpenELIS unavailable | Orders still accepted; Task queues as `requested` and is imported on the next poll after recovery |
| Kafka unavailable | 502 with the order explicitly marked `FAILED` — never a silent success |
| Poison (unparseable) message | Routed to `<topic>.dlq` and committed past, so it cannot stall the partition |
| Preliminary (unvalidated) report | Not forwarded; only `final` / `amended` / `corrected` leave the lab |

## Known limitations

Worth stating plainly, because each is a deliberate scope decision rather than
an oversight:

- **Order creation is a dual write.** The order row commits before the Kafka
  publish. A publish failure is caught and the order is marked `FAILED`, but
  the production answer is a transactional outbox. `services/His.Api/Program.cs`
  marks the seam.
- **The databases are containers.** On a laptop with only Docker Desktop, the
  "external database server" boundary is enforced by project and network
  separation rather than by separate hosts.
- **Result release is manual.** Driving OpenELIS's validation UI
  programmatically would couple the tests to its frontend; a lab user performing
  the step is also closer to what phase 3 is meant to exercise. `make results`
  covers everything downstream of the release.
- **The bridge implements FHIR itself** rather than running a HAPI FHIR server.
  It serves exactly the interactions OpenELIS uses — enough to be correct, not a
  general-purpose FHIR server.
- **Redis is provisioned but unused.** The brief lists it as optional;
  idempotency is enforced in the databases instead, where it survives a restart.
- **No authentication between services.** The sandbox relies on network
  isolation. Kong is where authentication would attach.
