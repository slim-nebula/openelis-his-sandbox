# his-api-service

Patients and lab orders — the HIS side of the OpenELIS integration.

This service is a **reference implementation**. It is never deployed: in
production your own `patient-service` fills this role. Its value is that it can
be read and copied, so it is written in the estate's stack and laid out the way
the estate's services are laid out.

It was ported from C# once the target platform was known. The 147-assertion
suite is black-box — it drives HTTP and inspects Postgres and Kafka — so it
validated the port without being rewritten. All 147 passed on the first run
against this service.

---

## Layout

Matches `patient-service`:

```
src/
  app.ts                    express, middleware, route mounting
  server.ts                 listen, Kafka, Consul, graceful shutdown
  config/                   env · db · kafka · logger · metrics · consul
  core/
    exceptions/             HTTPError and its subclasses
    middleware/             correlation · admin token · error handler
  shared/
    clients/                BaseApiClient, and the bridge client
    utils/                  serialization helpers
  modules/<domain>/
    containers/             static class, lazy singletons
    controllers/            HTTP in, HTTP out
    services/               domain logic
    models/                 SQL
    routes/                 express routers
    types/                  interfaces
    validators/             zod schemas
```

Three domains: `patients`, `lab-orders`, `catalogue`. Plus `modules/messaging`
for the outbox relay and the bridge-event consumer, which are background
workers rather than a request-served domain.

## Where it differs from the estate, and why

**Postgres through `pg`, not Prisma.** Prisma is right where a service *owns*
its schema — `patient-service` defines its tables in `schema.prisma` and
migrates them, so client and database cannot drift. This service does not own
its schema: `db/his/*.sql` does, applied by `scripts/migrate.sh`, the same
runner the bridge's database uses. A `schema.prisma` here would have to be kept
in step with SQL it does not control.

The hot paths would be raw anyway — the outbox claims rows with
`FOR UPDATE SKIP LOCKED`, the status update uses `IS DISTINCT FROM` so a
repeated status writes no audit row, and the catalogue upsert has a `WHERE` on
the *existing* row. Prisma expresses all three only through `$queryRaw`.

**A new HIS service that owns its tables should use Prisma, as yours do.**

**A registry outage does not stop the service.** `patient-service` calls
`process.exit(1)` if Consul registration fails; this logs and continues. It can
serve every request it has while unregistered — the bridge reaches it by
hostname and Kafka consults no registry — so refusing to start over a registry
outage would turn a discovery problem into a clinical one.

**The bridge is called directly, not through the gateway.** `BaseApiClient` is
present and points at `API_GATEWAY_URL` like yours, but the bridge is not an HIS
service: it is the one container straddling the boundary to OpenELIS. Routing
its traffic through the public edge would widen the path the architecture keeps
narrow, and would make a Kong outage stop the laboratory as well as the
ordering screen.

**Client routes return bare resources, not `{status, message, data}`.** The
frontend, the test suites and the bridge were built against that shape; changing
it would break a published contract for cosmetic consistency. **Errors do use
the envelope**, since those were never part of the contract.

## Authentication

`core/middleware/auth.middleware.ts` is `patient-service`'s middleware with
three changes: the algorithm is pinned, a Redis outage is logged once at each
edge rather than once per request, and whether the session was verified is
carried on `req.user` and counted in a metric.

The consequential file is `config/redis.ts`, not the middleware. The estate
creates the client with host and port only, which leaves `enableOfflineQueue`
at its default — so during an outage ioredis *queues* the revocation check
instead of failing it, and the degraded-mode catch block is never reached.
Requests hang rather than degrade. See docs/security.md §4.

Routes are grouped by who calls them:

| | |
|---|---|
| `/patients`, `/lab-orders`, `/test-catalogue` | user token, plus `LAB_ORDER_GROUP` |
| `/internal/*` | `x-internal-api-key` — the bridge is a service, not a person |
| `/admin/*` | shared operator token — run by the deployment, which has no user |
| `/health`, `/metrics` | nothing. A health check that can fail authentication reports an outage that is not happening |

## The two things worth copying

**The outbox.** `modules/lab-orders/models/lab-order.model.ts` commits the order
row, its audit row and the `lab.order.created` event in one transaction, and
publishes nothing. `modules/messaging/outbox.relay.ts` drains it. That single
commit is what makes "the order exists but billing never heard about it"
impossible — see `docs/his-kafka-findings.md`.

**The producer settings.** `config/kafka.ts` sets `idempotent: true` and bounds
in-flight requests. Without it a retry can land *after* a message produced
later, so an older status overwrites a newer one.

## Running it

Built and run by compose; there is no standalone mode, because it needs
Postgres, Kafka and Consul.

```bash
make up                 # whole sandbox
make logs S=his-api     # this service
```

| Path | |
|---|---|
| `GET /health` | liveness **and** database reachability — 503 if the database is unreachable |
| `GET /metrics` | Prometheus, same series as the estate |
| `GET /api/his/api-docs` | Swagger UI |
| `/internal/*` | bridge-facing, deliberately not routed by Kong |
