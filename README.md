# OpenELIS ↔ HIS Sandbox

An end-to-end reference integration between **OpenELIS Global 2** and a
microservices HIS: a small HIS estate (frontend → reverse proxy → Kong → Patient
+ Lab Order service), Kafka as the asynchronous backbone, a **bridge service**
that owns all laboratory interoperability, and OpenELIS running independently
against its own external database.

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

Two things make this more than a mock: OpenELIS runs the **real upstream images**
at a pinned release, and the bridge speaks the **actual** FHIR protocol OpenELIS
implements — no shortcut endpoints, no shared database.

---

## Start here

| You are… | Read |
|---|---|
| new to this | **[docs/architecture.md](docs/architecture.md)** — what runs and why |
| wiring your real HIS to it | **[docs/integration-guide.md](docs/integration-guide.md)** — step by step, and what production still needs |
| deciding what an order must carry | [docs/integration-field-map.md](docs/integration-field-map.md) |
| following an order through the system | [docs/data-flow.md](docs/data-flow.md) |
| running it, or fixing it at 3am | [docs/runbook.md](docs/runbook.md) |
| assessing risk before go-live | [docs/security.md](docs/security.md) |
| matching the estate's infra contracts | [docs/platform-integration.md](docs/platform-integration.md) |
| changing OpenELIS itself | [openelis-patches/README.md](openelis-patches/README.md) |
| looking at what we found in OpenELIS | [docs/upstream-issues/](docs/upstream-issues/) |

---

## Quick start

Docker Desktop with **at least 8 GB** allocated. OpenELIS's images are
`linux/amd64` only, so they run emulated on Apple Silicon.

```bash
make secrets         # generate .env from .env.example      ← first run only
make up              # certificates, config, databases, build and start
make sync-catalogue  # read the orderable test menu from OpenELIS  ← required
make token           # sign in — the clinical API needs a user token
make smoke           # confirm the platform before sending clinical data
```

Then open the frontend at **http://localhost:8090** and the OpenELIS UI at
**https://localhost** (`admin` / see `make urls`).

`make up` is idempotent and safe to re-run. `make urls` prints every entry point.

## Tests

```bash
make smoke           platform and wiring
make auth            tokens, revocation, degraded mode, the audit trail
make catalogue-test  the test menu, and the specimen abbreviations
make negative        outages: broker, Redis, API, OpenELIS
make rejection       refusal, drift, and a withdrawn specimen
make e2e             an order into OpenELIS   (pauses for the manual lab step)
make results         the result return path
make corrections     corrections and retractions of a released result
make progress        laboratory progress within an order
```

The first five run unattended and are the ones to trust before a change:
**196 checks, currently 0 failures.** `make e2e` deliberately pauses for a human
to release a result in the OpenELIS UI, because that step is a real laboratory
action and pretending otherwise would prove nothing.

## Layout

```
compose/            data.yml (external DBs) · platform.yml · apps.yml · openelis.yml
db/                 HIS and bridge schemas, applied on first database start
gateway/            Kong declarative routes · edge nginx config
services/his-api    Patient + Lab Order service (Node 20 / TypeScript)
services/Bridge     Kafka consumer + FHIR R4 server + correlator (.NET 10)
frontend/           the doctor's test client
openelis/           volume assets, common.properties template
openelis-patches/   our patches to OpenELIS, and the rules governing them
scripts/            config rendering, and every test suite
docs/               see the table above
```

## A note on OpenELIS itself

The stack runs **stock upstream images** by default, pinned to a named release
(`OE_VERSION`), never `:develop`. We carry exactly **one** patch, for a defect
nothing outside OpenELIS can fix; three other defects we found are handled
entirely on our side. The rules, the patch, and the two candidates we rejected
are in [openelis-patches/README.md](openelis-patches/README.md).

`docker ps` always shows which build is running.
