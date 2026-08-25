# Architecture

What runs, why it exists, and where state lives.

This is the first thing to read. It describes the sandbox as built — every
container, network and database below was read off the running system, not
sketched.

---

## 1. The shape of it in one paragraph

A doctor places a lab order in the HIS. The HIS publishes an event. A **bridge**
consumes it, turns it into FHIR, and holds it until OpenELIS asks. OpenELIS polls
the bridge, imports the order, and a laboratory technician does the physical
work. When a result is released, OpenELIS pushes it to the bridge, which
correlates it back to the original order and hands it to the HIS.

Two systems, neither of which knows the other exists. Everything specific to
OpenELIS lives in one place: the bridge.

---

## 2. Containers

Fourteen containers in three groups. **Stock** means an unmodified upstream image;
**ours** means built from this repository.

### The HIS sandbox — stands in for your real HIS

| container | image | ours? | what it is |
|---|---|---|---|
| `his-frontend` | `his-sandbox/frontend:local` | ours | the doctor's screen: search a test, place an order |
| `his-edge-proxy` | `nginx:1.27-alpine` | stock | the public entrance, port **8090** |
| `his-kong` | `kong:3.9.3` | stock | API gateway — routing, auth enforcement |
| `his-api` | `his-sandbox/his-api:local` | ours | patients, orders, results, the test menu |
| `his-kafka` | `apache/kafka:4.3.1` | stock | the event backbone |
| `his-redis` | `redis:7-alpine` | stock | user sessions |
| `his-consul` | `hashicorp/consul:1.20` | stock | service registry and health |

### The bridge — the integration itself

| container | image | ours? | what it is |
|---|---|---|---|
| `bridge` | `his-sandbox/bridge:local` | ours | the whole integration: consumes order events, maps to FHIR, serves OpenELIS's poll, receives results, correlates them back |

**One container.** Everything OpenELIS-specific is inside it — the FHIR shapes,
the sample-type vocabulary, the polling contract, the correlation chain.

### OpenELIS — the laboratory system

| container | image | ours? | what it is |
|---|---|---|---|
| `openelis-webapp` | `itechuw/openelis-global-2:3.2.2.0` | **stock** | the LIS application |
| `openelis-frontend` | `…-frontend:3.2.2.0` | stock | the lab user's React UI |
| `openelis-proxy` | `…-proxy:3.2.2.0` | stock | OpenELIS's own nginx, ports **80/443** |
| `openelis-fhir` | `…-fhir:3.2.2.0` | stock | HAPI FHIR store, OpenELIS's working store |
| `openelis-db-external` | `…-database:3.2.2.0` | stock | the laboratory database |

Plus two one-shot containers that exit after doing their job: `oe-certs` /
`openelis-peer-cert` (issue the mTLS material) and `openelis-trust-bridge`
(imports our CA into OpenELIS's truststore).

> **On patching.** The webapp is the only image we ever build ourselves, and only
> when `OE_IMAGE_REPO=his-sandbox`. The default is `itechuw` — stock. See
> [openelis-patches/README.md](../openelis-patches/README.md). `docker ps` always
> shows which is running.

---

## 3. Networks — the boundary is physical

Four networks. Membership is the interesting part.

| network | who is on it |
|---|---|
| `oe-sandbox-net` | the HIS side — edge proxy, kong, his-api, frontend, kafka, redis, consul, **bridge** |
| `oe-integration-net` | **`bridge` and `openelis-webapp`. Nothing else.** |
| `oe-data-net` | the database servers, and only the services that need them |
| `oe-internal-net` | OpenELIS's own internals — proxy, webapp, fhir |

Two consequences fall out of that table, and they are the point of it:

- **`his-api` is not on `oe-integration-net`.** The HIS *cannot* reach OpenELIS,
  even by accident. Every order goes through the bridge.
- **`openelis-webapp` is not on `oe-sandbox-net`.** OpenELIS cannot reach the HIS
  API, Kafka or Redis. It only ever talks to the bridge.

The separation isn't a convention people have to remember. A container that tried
to shortcut it would fail to resolve the hostname.

---

## 4. Where state lives

Six places. Three are databases, three are not, and only some survive a restart.

| store | contains | survives restart? |
|---|---|---|
| `his_sandbox` (schema `his`) | patients, lab orders, results, test-menu mirror, audit trail | yes — volume |
| `bridge_sandbox` (schema `bridge`) | FHIR resources, order tracking, catalogue, delivery leases, dead letters | yes — volume |
| `clinlims` | everything the laboratory owns: samples, analyses, results | yes — volume |
| Kafka | order events **in flight** | yes — but see below |
| Redis | user sessions | **no** — a restart is a system-wide logout, by design |
| Consul | service registry, health | no — rebuilt on start |

**Two servers, three databases.** `his_sandbox` and `bridge_sandbox` share the
`his-db-external` server — a sandbox convenience to save a container. They are
separate *databases*, not schemas in one, so **no service can join across them**:
the bridge cannot read `his.patients`, it must call the HIS API. In production
they would be separate servers, because the HIS and the bridge are different
trust domains.

**Kafka is a source of truth while an order is in flight**, not just a pipe. An
order accepted by the HIS but not yet delivered exists *only* as a Kafka event
plus an outbox row. It currently runs as **one broker with replication factor 1** —
fine for a sandbox, a single point of failure for a laboratory. See
[integration-guide.md](integration-guide.md#from-integration-to-production).

---

## 5. How an order actually travels

```
doctor
  │  browser
  ▼
his-edge-proxy ──► his-kong ──► his-api ──┬──► his_sandbox   (order row + outbox)
                                          │
                                          └──► Kafka  lab.order.created
                                                  │
                                                  ▼
                                              bridge  ── maps to FHIR ──► bridge_sandbox
                                                  ▲
                        OpenELIS polls ───────────┘   GET /fhir/Task?status=requested&owner=…
                                                  │
                                              openelis-webapp ──► clinlims
                                                  │
                                          (a human accessions, runs, releases)
                                                  │
                        OpenELIS pushes ──────────▼   FHIR Subscription, rest-hook
                                              bridge  ── correlates ──► Kafka lab.result.released
                                                  │
                                                  ▼
                                              his-api ──► his_sandbox  (result + visit + order number)
```

Two details that matter more than they look:

**OpenELIS pulls, we don't push.** The bridge holds the order and waits. That is
OpenELIS's design, and it means the laboratory is never interrupted by us.

**Results correlate by a two-hop chain**, not by patient or timestamp:
`DiagnosticReport → ServiceRequest → ServiceRequest → order number`. That is why
a result lands on the right order even when a patient has several open.

---

## 6. What the doctor can order, and why

The menu is **synced from OpenELIS**, never authored in the HIS. Whatever the
laboratory has enabled and marked orderable is what appears in the search box —
one row per (test, specimen).

An order then sends back the same two things the laboratory used to identify it:
the **LOINC code** and the **specimen**. That closes the loop, and it is the
reason there is no ambiguity: we never invent an identifier or map between
vocabularies.

The one subtlety is that "the specimen" needs two forms — the name the doctor
reads (`Whole Blood`) and the local abbreviation OpenELIS matches on
(`Whole Bld`). Both are synced. Getting this wrong binds the wrong test
*silently*; see [integration-field-map.md](integration-field-map.md#3-why-the-specimen-is-load-bearing).

---

## 7. Trust and identity

| hop | how it is secured |
|---|---|
| browser → edge → Kong | user token, verified at the gateway |
| his-api → Kafka | inside `oe-sandbox-net`, not exposed |
| **bridge ↔ OpenELIS** | **mutual TLS** — client certificates both ways, issued by our own CA |
| bridge ops endpoints | operator token or an estate user token |
| bridge → OpenELIS REST | HTTP basic as a service user (OpenELIS gates its catalogue endpoints behind `hasRole('ADMIN')`) |

The mTLS material lives in the `oe-certs`, `oe-keys` and `oe-key-trust-store`
volumes and is issued by `make certs`. OpenELIS reads its truststore once, at
startup, which is why `make trust-bridge` restarts it.

---

## 8. Reading order

| you are | read |
|---|---|
| new to this | this file, then [data-flow.md](data-flow.md) |
| wiring the real HIS | [integration-guide.md](integration-guide.md) |
| deciding what to send | [integration-field-map.md](integration-field-map.md) |
| running or fixing it | [runbook.md](runbook.md) |
| assessing risk | [security.md](security.md) |
| changing OpenELIS itself | [openelis-patches/README.md](../openelis-patches/README.md) |
