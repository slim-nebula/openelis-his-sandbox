# Review request: the bridge rewrite, Node/Express

*A handoff to a fresh reviewer. Paste this, or say "read BRIDGE-REWRITE-REVIEW.md
and do what it asks."*

---

## What I want from you

Two things, in this order:

1. **Find what is wrong with the work so far.** Not a verification pass — an
   adversarial one. I have written ~900 lines of a ~5,000-line rewrite and I am
   the wrong person to judge whether the foundation is sound, because I chose it.
2. **Give me a plan to continue**, including changing the plan if you think the
   sequencing or the architecture is wrong.

**Please disagree where you disagree.** The most useful outcome is you telling me
the module layout is wrong, or that a decision I recorded as settled should be
reopened, or that phase 2 should not be phase 2. I would rather rework 900 lines
now than 5,000 later. A review that concludes "this looks good, continue" is
only useful if you actively tried to break it first.

---

## The situation in one paragraph

This repo is a working OpenELIS ↔ HIS integration sandbox, built as a **showcase
for a client's developers**. Everything in it is Node/TypeScript except the
integration service itself, `services/Bridge`, which is .NET. The client
confirmed their real estate (at `~/Documents/HIS Project`) is Node + Express +
TypeScript throughout, and asked for the bridge to be rewritten to match — so the
one component their team cannot maintain becomes one they can copy. The .NET
bridge works and passes **355 black-box checks**; those checks are the acceptance
criterion for the rewrite, because they are HTTP/database/Kafka assertions that
do not care what language serves them.

---

## Orientation — read these, in this order

| What | Where | Why |
|---|---|---|
| The approved plan | `~/.claude/plans/valiant-forging-peacock.md` | Decisions, port map, contract-fidelity list, 8 phases |
| The service being replaced | `services/Bridge/*.cs` (17 files, ~5,100 lines) | Especially `OrderMapper.cs`, `ResultCorrelator.cs`, `BridgeStore.cs`, `Access.cs`, `MutualTls.cs` |
| What I have written | `services/bridge-node/src/**` | ~900 lines, phases 0–1 |
| The style to match | `services/his-api/src/**` | The other Node service in this repo |
| The style they actually write | `~/Documents/HIS Project/HIS-patient-service-develop-2/src/**` | Express 5, ESM, Prisma |
| The contract | `scripts/test-*.sh`, `compose/apps.yml`, `db/bridge/*.sql` | 355 checks; several pin exact strings |
| Prior audit of the whole system | `AUDIT.md` | Context on what was recently changed and why |

Git: the rewrite so far is commit `680ece3`. `git log --oneline -8` gives the
recent history.

---

## What is done, and how far I actually verified it

**Phase 0 — deterministic resource ids.** The single highest-risk item. Ids are
RFC 4122 v5 UUIDs; a drifted implementation would make every existing clinician a
*new* `Practitioner` in the laboratory's records, permanently and silently.

Verified: Node matches Python's `uuid.uuid5` including the published
`python.org` vector, and reproduces a real live id —
`task|137539b5-2690-46ea-b808-bcbc0d31352c` → `07e60d38-f066-5d30-8c6a-9d9acd56b930`,
which is what the .NET bridge wrote for order `LAB-20260824-137539B5`.

**Phase 1 — scaffold and platform surface.** `config/{env,db,logger,metrics,kafka,consul,redis}`,
`core/{exceptions,middleware}`, the catalogue module, `app.ts`, `server.ts`.
Endpoints: `/health`, `/`, `/catalogue`, `/catalogue/syncs`.

Verified: run locally against the real `bridge_sandbox` database and **diffed
field-for-field against the running .NET container**. Every key matches.
`/catalogue/syncs` refuses without a token (401) and serves with one (200).

**What I have NOT done: run a single one of the 355 suite checks against the
Node service.** Nothing is wired into compose. `services/Bridge` still builds and
still serves the laboratory. Everything above is manual curl plus a typecheck.

---

## The decisions I would most like challenged

These are recorded as settled in the plan. I am not confident about all of them.

1. **Splitting `BridgeStore.cs` into a model per module.** The C# is one
   640-line class doing six unrelated jobs. I plan `modules/*/models/*.model.ts`.
   Better seams — but the six jobs share a connection and some queries touch two
   concerns (the ledger reads `order_tracking` *and* `forwarded_results`). Is
   this a real improvement or am I creating six files that import each other?

2. **`express.json()` mounted per-router, not globally.** Because the FHIR
   surface receives `application/fhir+json` and must tolerate whatever OpenELIS
   sends. I have not yet written that surface. Is per-router right, or should
   there be a single permissive body parser with a type matcher? This decision
   is cheap now and expensive in phase 2.

3. **Accepting two shapes of `BRIDGE_DB_CONNECTION`** (Npgsql `Host=…;User=…`
   *and* a `postgres://` URL) rather than changing compose to emit a URL. I chose
   not to rename or reshape a variable that is set in compose and in deployment
   notes. But a Node service parsing a .NET connection string is odd to read.
   Which is the better example for their developers?

4. **Log shipping is not awaited at startup**, diverging from `his-api`, which
   does await it. My reasoning: KafkaJS `connect()` retries for ~a minute before
   rejecting, so awaiting turns a slow broker into a bridge that is not serving
   OpenELIS's poll — and the .NET version had the non-blocking property. But now
   two Node services in one repo start differently. Should I instead *fix
   his-api* to match?

5. **Gauges constructed lazily, on first successful refresh.** prom-client
   exports a gauge at `0` from creation, and for an age or a backlog `0` is the
   healthiest possible reading — which is exactly how the .NET version once
   published "nothing stuck, catalogue fresh" while never having queried the
   database. Lazy construction makes a broken collector produce an *absent*
   metric. Is this too clever? Is there a plainer way that keeps the property?

6. **Comment density.** This repo's house style is heavy "why, not what"
   comments, and I have matched it. Tell me if I have crossed from explanation
   into noise, with specific examples.

---

## The traps already known (so you do not re-derive them)

- **`services/bridge` and `services/Bridge` are the same path.** APFS is
  case-insensitive. Hence the temporary name `bridge-node`, renamed in phase 8.
- **node-postgres returns `bigint` and `numeric` as STRINGS.** `count(*)` and
  `extract(epoch …)` do not arrive as numbers. This bit the .NET version twice
  (see the `bridge-dapper-type-mapping` memory). SQL casts `::int` /
  `::double precision`, and callers coerce.
- **`Task.owner` must be an `Organization` reference.** A `Practitioner/…` value
  silently hijacks the requester on OpenELIS's side and attributes every order to
  the routing identity.
- **`ServiceRequest.id` is the order number verbatim**, not a UUID — OpenELIS's
  Incoming Orders view reads `ServiceRequest/{external_id}` directly.
- **Patient names must not contain digits.** OpenELIS's `lastNameCharset`
  excludes them; an order for "Doe 2" stalls at `SENT_TO_LIS` with no rejection
  and no dead letter.
- **`make smoke` caps log volume**: 16 `/health` requests must produce ≤ 8 log
  lines. Do not add a request logger.
- **The build host is 8 GiB** and the Docker daemon wedged once under repeated
  image builds with the full stack up. Stop the stack before building.

---

## Specific things worth your scrutiny

- `services/bridge-node/src/config/metrics.ts` — the lazy gauge registration.
- `services/bridge-node/src/core/middleware/ops-access.ts` — compare against
  `services/Bridge/Access.cs` and `Identity.cs`. The status-code and message
  matrix is pinned by `scripts/test-auth.sh` §7 and `scripts/test-negative.sh`.
  I believe I matched it; check the 503-when-unconfigured path especially.
- `services/bridge-node/src/config/env.ts` — every variable name here is a
  contract. Compare against the `environment:` block in `compose/apps.yml` and
  confirm nothing is missing or renamed.
- `services/bridge-node/src/app.ts` — middleware order, and whether `/catalogue`
  being mounted twice (open router, then guarded router on the same prefix) is
  sound in Express 5 or a subtle routing bug waiting to happen.

Verify rather than trust:

```bash
cd services/bridge-node && npm install && npx tsc --noEmit && npm run build
# run it against the live database, no Docker needed:
BRIDGE_DB_CONNECTION="Host=localhost;Port=55432;Database=bridge_sandbox;Username=bridge_app;Password=bridge_app_pw" \
  SERVICE_PORT=18099 node dist/server.js
curl -s localhost:18099/health; curl -s localhost:18099/catalogue | head -c 300
# and against the .NET one still running, to diff:
docker exec bridge curl -s http://127.0.0.1:8080/health
```

---

## The plan I would like you to critique or replace

Remaining phases, each gated on a suite:

| # | Scope | Gate |
|---|---|---|
| 2 | FHIR store + `/fhir` surface + delivery lease | OpenELIS imports an order; `make e2e` |
| 3 | order consumer, mapper, refusal matrix | `make requester`, `make rejection` |
| 4 | result correlator, progress tracker | `make results`, `make panel`, `make corrections` |
| 5 | catalogue sync, OpenELIS REST client | `make catalogue-test` |
| 6 | ops surface: dead letters, ledger, retention, export monitor, gauges | `make monitoring`, `make negative` |
| 7 | mutual TLS listener, peer pinning | `make negative` mTLS block |
| 8 | delete the C#, repoint ~40 doc references, rename to `services/bridge` | full sweep, 355 |

Questions I actually have about it:

- **Is phase 2 the right next step?** It is the riskiest — if OpenELIS will not
  import from the Node bridge, everything above it is wasted. That argues for
  doing it next. But it also depends on the FHIR store, the lease, and the
  serialisation, so it is the largest phase. Should it be split?
- **Should mTLS (phase 7) move earlier?** It is the one piece with no Node
  precedent in this repo and the most unknown. Late failure there is expensive.
- **Is there a way to run the suites incrementally**, rather than a big-bang
  cutover at each gate? The container name must stay `bridge`, so both services
  cannot serve at once — but perhaps a phase could run the Node service on a
  second container and proxy only some paths to it. Is that worth the complexity,
  or is switch-and-revert good enough?
- **What would you cut?** If this has to ship sooner, which phases are truly
  required and which could keep the .NET behaviour documented as a gap?

---

## Ground rules

- **Do not change any test in `scripts/`.** If a suite would need editing to
  pass, that is a porting bug, not a suite problem.
- **Do not modify `services/Bridge`** — it is the working reference and the
  fallback.
- **Read before asserting.** Several claims in this document are mine and could
  be wrong; the code and the suites are the authority.
- Read-only is fine for the whole review. If you want to change something,
  propose it rather than doing it, unless it is obviously trivial.
