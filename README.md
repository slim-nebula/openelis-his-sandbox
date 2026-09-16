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
| new to this | **[docs/architecture.md](docs/architecture.md)** — what runs, why, and how an order travels |
| wiring your real HIS to it | **[docs/integration-guide.md](docs/integration-guide.md)** — step by step, and what production still needs |
| deciding what an order must carry | [docs/integration-contract.md](docs/integration-contract.md) |
| running it, or fixing it at 3am | [docs/operations.md](docs/operations.md) |
| assessing risk before go-live | [docs/security.md](docs/security.md) |
| **improving your own HIS codebase** | **[docs/his-findings.md](docs/his-findings.md)** — defects and designs found in `HIS Project`, with working code to copy |
| wiring lab tests to billing and CPT codes | [docs/billing-integration.md](docs/billing-integration.md) |
| changing OpenELIS itself | [openelis-patches/README.md](openelis-patches/README.md) |
| looking at what we found in OpenELIS | [docs/upstream-issues/](docs/upstream-issues/) |
| why the integration is shaped as it is | [docs/archive/](docs/archive/) — the audit and the acceptance record, kept as history |

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
make unit             the bridge's pure functions — no stack required
make smoke            platform and wiring
make auth             tokens, revocation, degraded mode, the audit trail
make catalogue-test   the test menu, and the specimen abbreviations
make collection       the outpatient and inpatient collection workflows
make requester        the ordering clinician reaching the laboratory's screen
make panel            a report with several analytes — the whole panel, not its first
make monitoring       the gauges, the alert rules, and whether they can fire
make patient-refresh  does a corrected patient name reach the laboratory? (it does not)
make negative         outages: broker, Redis, API, OpenELIS
make rejection        refusal, drift, and a withdrawn specimen
make results          the result return path
make corrections      corrections and retractions of a released result
make e2e              an order into OpenELIS   (pauses for the manual lab step)
make progress         laboratory progress within an order
```

The twelve suite targets run unattended and are the ones to trust before a
change: **355 checks, currently 0 failures.** `make unit` is separate and needs
nothing running — 64 assertions over the pure functions whose failure would be
silent, chiefly the deterministic resource ids and the decimal precision of a
result. `make e2e` deliberately pauses for a human
to release a result in the OpenELIS UI, because that step is a real laboratory
action and pretending otherwise would prove nothing.

Two of these assert things you might not expect a test to assert.
`make patient-refresh` asserts that a corrected patient name **does not** reach
the laboratory — it is a tripwire on a known upstream defect, written to go red
the day a release fixes it. `make monitoring` checks that every metric named by
an alert still resolves to a real series, because Prometheus reports a rule
pointing at a nonexistent metric as perfectly healthy.

## What this does not do

Each is a deliberate scope decision rather than an oversight, and knowing them
up front saves re-discovering them later.

- **The databases are containers.** On a laptop with only Docker Desktop, the
  "external database server" boundary is enforced by project and network
  separation rather than by separate hosts.
- **Patient names containing digits are rejected by OpenELIS**, and the order
  then retries indefinitely without ever failing. It is the one stall with no
  error anywhere — see [docs/operations.md](docs/operations.md) and
  [upstream issue 07](docs/upstream-issues/07-patient-name-never-refreshed.md).
- **An inpatient order can wait forever.** `AWAITING_COLLECTION` has no timeout,
  deliberately: expiring a real pending order because a nurse was busy would be
  worse than leaving it visible. It is the ward's worklist, and a real estate
  would put an escalation on top of it rather than an expiry underneath.
- **Nothing verifies who drew the blood.** Recording a collection is attributed
  through the token and audited, but a ward user asserting a draw time is
  trusted. See [docs/security.md](docs/security.md) §9.
- **Result release is manual.** Driving OpenELIS's validation UI
  programmatically would couple the tests to its frontend, and a lab user
  performing the step is closer to what it actually is. `make results` covers
  everything downstream of the release.
- **The bridge implements FHIR itself** rather than running a HAPI FHIR server.
  It serves exactly the interactions OpenELIS uses — enough to be correct, not a
  general-purpose FHIR server.
- **No authentication between services inside the sandbox.** It relies on
  network isolation; Kong is where authentication would attach.
- **No authentication on the FHIR endpoint itself.** It is protected by mutual
  TLS at the transport layer instead, because OpenELIS cannot authenticate to a
  remote FHIR source at all.

---

## Operations

```bash
make alerts          what is firing right now
make reconcile       the order ledger — taken on vs resulted, day by day
make dead-letters    failures that need a human
make export-status   is OpenELIS still pushing results to us?
```

## Layout

```
compose/            data.yml (external DBs) · platform.yml · apps.yml · openelis.yml
db/                 HIS and bridge schemas, applied on first database start
gateway/            Kong declarative routes · edge nginx config
monitoring/         Prometheus scrape config · the alert rules
services/his-api    Patient + Lab Order service (Node 20 / TypeScript)
services/bridge     Kafka consumer + FHIR R4 server + correlator (Node 20 / TypeScript)
frontend/           the doctor's test client
openelis/           volume assets, common.properties template
openelis-patches/   our patches to OpenELIS, and the rules governing them
scripts/            config rendering, and every test suite
docs/               see the table above
```

## A note on OpenELIS itself

The stack runs **stock upstream images** by default, pinned to a named release
(`OE_VERSION`), never `:develop`. We carry exactly **one** patch, for a defect
nothing outside OpenELIS can fix; the other six defects we found are handled
entirely on our side, worked around, or simply lived with — one of them, the
ordering clinician, turned out to need nothing more than the resource *type* of a
configuration value.

Two are lived with rather than worked around, and both are the same bug in
different resources: once OpenELIS has imported a **Practitioner** or a
**Patient**, it never refreshes them. A name corrected in the HIS never reaches
the laboratory, and re-sending is precisely what does not work. That matters most
for the patient, where it means the two systems disagree about whose specimen is
on the bench — see [07](docs/upstream-issues/07-patient-name-never-refreshed.md).

The rules, the patch, and the two
candidates we rejected are in
[openelis-patches/README.md](openelis-patches/README.md); the reports themselves
are in [docs/upstream-issues/](docs/upstream-issues/).

`docker ps` always shows which build is running.
