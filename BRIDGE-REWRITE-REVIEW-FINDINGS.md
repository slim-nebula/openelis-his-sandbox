# Review findings: the bridge rewrite, phases 0–1

*Fable 5's answer to BRIDGE-REWRITE-REVIEW.md. Adversarial pass over
`services/bridge-node` (~900 lines), the six flagged decisions, and the
remaining plan. Everything below was verified against the code, the suites and
the running stack — not taken from the handoff document.*

**Verdict in one line: the foundation is sound and the style is right, but the
plan's sequencing has one real flaw — phase 2's gate is unreachable without the
mTLS listener — and there are two fidelity regressions worth fixing before more
code sits on top of them.**

What was re-verified, not trusted: `npx tsc --noEmit` and `npm run build` are
clean; the service ran locally against the live `bridge_sandbox` database;
`/`, `/health` and `/catalogue` were diffed against the running .NET container
(root is byte-identical; health has identical keys; the catalogue's 17 tests
are **fully identical including key order**); `/catalogue/syncs` refuses 401
without a token and serves 200 with one; every variable in `compose/apps.yml`'s
`environment:` block exists in `env.ts` under the same name, and the parser
ignores `Include Error Detail=true` correctly.

---

## Findings, most important first

### F1 — SEQUENCING: phase 2's gate cannot pass without mTLS (move phase 7 into phase 2)

Verified against the running deployment: `.env` sets `BRIDGE_MTLS_ENABLED=true`
and OpenELIS's `common.properties` pins
`org.openelisglobal.remote.source.uri=https://bridge.openelis.org:8443/fhir` —
the mutually authenticated port and nothing else. The live bridge shows
`bridge_fhir_requests_total{transport="mtls"} 567`. OpenELIS has no plaintext
fallback; its one configured URI is 8443.

So the plan's phase 2 gate — "OpenELIS imports an order" — is unreachable with
the Node service in compose until the TLS listener, the fingerprint pin and the
port guard exist. That is currently phase 7. Reordering options considered and
rejected: turning mTLS off and repointing OpenELIS's URI for phases 2–6
violates the standing rule that OpenELIS's configuration is not touched, and
would gate every phase on a configuration that is not the one that ships.

**Change:** split phase 2 into 2a and 2b, and move mTLS into 2a (details in the
revised plan below). This also answers the handoff's own question — mTLS is the
one piece with no Node precedent in the repo, and this brings its risk to the
front, where the plan's own logic says risk belongs.

### F2 — FIDELITY REGRESSION: every bridge log line ships to the shared topic as `level: "info"`

`logger.ts`'s Kafka stream hardcodes `level: 'info'` and puts the whole
formatted console line (timestamp and level prefix included) into `message`.
This is a faithful copy of **his-api's** logger — but the service being
*replaced* did it right: `Platform.cs`'s `KafkaLogProvider` ships the real
level (`level = line.Level`, line 272).

Consequence after cutover: a Grafana/Loki query filtering the bridge's log
stream on `level="error"` or `"warn"` silently returns nothing. `make smoke`
only asserts the envelope's *keys*, so no suite catches it — this is exactly
the class of silent break the handoff asked to hunt.

**Fix (small):** replace the formatted-stream transport with a minimal custom
winston `Transport` whose `log(info)` receives the structured `info.level` and
`info.message`, and ship those. Keep his-api as it is — its suites pass and it
is out of scope — but the bridge should not *regress* to match a wart.

### F3 — `problemResponse`'s title map is incomplete, and it is about to get callers

Verified live: the .NET 401 body is
`{"type":"https://tools.ietf.org/html/rfc9110#section-15.5.2","title":"Unauthorized",…}`;
the Node body is `{"type":"about:blank","title":"Unauthorized",…}`. No suite
pins `type` or `title` (they assert status codes and `detail` strings), so
nothing breaks — but the map yields `title: "Error"` for 503 today, and phases
5–6 add the 501 ("Not Implemented") and more 503 refusals. Extend the map to
proper reason phrases (503, 501, 404, 409, 500) **now**, while it has three
callers instead of thirty. Keeping `type: "about:blank"` is fine — it is more
correct than ASP.NET's link-into-an-RFC habit; record it as a deliberate
divergence in the README.

### F4 — group membership check trusts the token's JSON shape

`ops-access.ts` casts `payload.group_names` and calls
`principal.groups.includes(group)`. If IAM ever emits `group_names` as a scalar
string instead of an array, the runtime value sails through the cast and
`String.prototype.includes` does **substring** matching — a group named `ops`
would match a token carrying `"developers"`. The C# side is immune by
construction (`FindAll` always yields per-value string claims).

**Fix (one line):** `Array.isArray(payload.group_names) ? payload.group_names : []`.

### F5 — refusal shape for *unmatched* paths differs, in both directions

Verified live:

| Request | .NET | Node |
|---|---|---|
| `GET /catalogue/nonexistent`, no token | **404** (filter runs only on matched endpoints) | **401** problem+json (guard runs before matching) |
| `GET /nope` | 404, empty body | 404, **Express's HTML** "Cannot GET /nope" |

No suite pins either. The Node 401 is arguably *better* (a guarded prefix that
doesn't reveal which paths exist), so keep it — but add a JSON 404 fallback
handler (problem+json) after the routers so the bridge never serves HTML, and
list both as deliberate divergences in the README. The FHIR surface must
additionally answer unknown-resource 404s as OperationOutcome — phase 2b.

### F6 — `express.json()`'s default body limit is 100 KB; the FHIR surface will exceed it

The per-router decision is right (see D2 below), but flagging this now because
the handoff said this decision is "cheap now and expensive in phase 2":
Express's default `limit` is **100kb**, and Kestrel's default request cap was
~30 MB. A result bundle carrying a panel's observations, or a Task update with
narrative, can exceed 100 KB and would be refused 413 — a break no suite
catches until a big panel crosses. The FHIR router must mount
`express.json({ type: ['application/fhir+json', 'application/json'], limit: '10mb' })`.

### F7 — smaller notes, none blocking

- **`syncedAt` precision:** Node emits `.347Z` (ms), .NET emitted
  `.347097+00:00` (µs). Only asserted non-null; cosmetic. Keep the phase-1
  habit of diffing every timestamp-bearing field against the .NET output in
  phase 2b, because FHIR `instant` fields land in stored `jsonb` that
  OpenELIS re-reads.
- **Event-producer chatter:** the domain `Kafka` instance in `kafka.ts` leaves
  KafkaJS's default logger on; during a broker outage it prints several ERROR
  lines per second to the console (observed locally). Console-only — the
  topic's ≤8-line cap is safe — but pass `logLevel: logLevel.ERROR` to keep
  `docker logs bridge` readable in an incident, which is exactly when it is
  read.
- **Shutdown does not drain:** `plaintext.close()` is not awaited before
  `process.exit(0)`, so an in-flight import can be cut mid-response on
  SIGTERM. Await the close (with a short timeout) in phase 7 when the second
  listener arrives.
- **`ops-access` logs `req.originalUrl`** (query string included) where the C#
  logged `Path`. `test-auth.sh` only greps `by user 11`, so it passes; the
  query in the audit line is arguably richer. Keep, noted.
- **`ProblemError` is dead code** — `errorHandler` already renders every
  `HTTPError` as problem+json, so the subclass adds nothing. Delete it until a
  phase needs a distinction.

---

## The six challenged decisions — verdicts

**D1. Splitting BridgeStore per module — KEEP.** The fear ("six files that
import each other") dissolves if models own *questions*, not tables: the
reconciliation model may freely read `order_tracking` and `forwarded_results`
in one query — that query belongs to ops because ops asks it. One rule keeps
the seams honest: **no model imports another model.** If two modules need the
same read, it is either one SQL statement duplicated with a comment saying so,
or a sign the query belongs to exactly one of them.

**D2. Per-router `express.json()` — KEEP**, with the phase-2b shape settled
now: the FHIR router mounts its own parser with a `type` matcher for
`application/fhir+json` and a raised `limit` (F6). A single global permissive
parser would be simpler but would parse bodies on routes that must not have
them and couple the two surfaces' limits.

**D3. Dual-shape `BRIDGE_DB_CONNECTION` — KEEP, and it is not merely
defensible, it is load-bearing:** during phases 2a–7 the switch-and-revert
safety story requires *both* implementations to boot from the *same* compose
value, and the .NET one can only read the Npgsql shape. Reshaping the variable
would delete the one-line revert. Revisit at phase 8: once the C# is gone,
optionally flip compose to a `postgres://` URL and shrink the parser — or keep
it as the documented example of meeting a deployment where it is.

**D4. Log shipping not awaited — KEEP the divergence.** The reasoning is
correct, the .NET service had the property, and the comment in `server.ts`
states it. Do not edit his-api inside this rewrite — it passes its suites and
is the estate's reference. Propose the same change to his-api as a separate
follow-up commit after phase 8, so the two services converge in the right
direction rather than the wrong one.

**D5. Lazy gauges — KEEP; it is not too clever.** The alternative (eager
registration with a sentinel) destroys the property the suites depend on:
`test-monitoring.sh` fails a gauge that is *absent* with "the refresh has never
succeeded" — absent-means-broken is asserted, and `alerts.yml` names all four
gauges. The comment already tells the story. One nit: `integrationGaugesPublished()`
has no caller yet; keep it only if phase 6 uses it.

**D6. Comment density — right side of the line, with two trims.** Nearly every
comment states a constraint the code cannot (the `-1` sentinels, the
Organization owner, the offline-queue behaviour). Trim: the `queryOne` comment
in `db.ts` ("The shape most reads here actually want" — the signature says it),
and `ProblemError`'s comment goes with the class (F7). The Dockerfile's
`npm ci` comment is borderline but earns its keep in a showcase repo.

---

## The revised plan

Phases 0–1 stand. The rest, re-sequenced — one change of substance (mTLS
forward), one gate correction, and one clarification of how phases end.

| # | Scope | Gate |
|---|---|---|
| **2a** | **Mutual TLS**: `config/mtls.ts` (https listener, `requestCert`, fingerprint pin in `secureConnection`, `setSecureContext` hot reload, no-crashloop on missing certs), `fhir-peer-guard.ts` (localPort check, transport counter, OperationOutcome refusals), `/fhir` stub on both ports. Plus the F2/F3/F4 fixes and a JSON 404 fallback (F5). | Handshake proven from a **side container** (below): openssl with the OpenELIS client cert succeeds, without it is refused at handshake (curl exit 35/`000`); `bridge_fhir_requests_total{transport="mtls"}` increments. No cutover. |
| **2b** | FHIR store + serializer + search/read/update/create/bundle + delivery lease (CTE verbatim). FHIR router body parser per F6. | Cutover. OpenELIS polls over mTLS and **imports a hand-seeded order** (clone a real order's resource rows under fresh ids); lease withholds it from the next poll. `make smoke`. **Not `make e2e`** — e2e creates an order through the HIS, which needs phase 3's consumer; the plan had this gate double-booked. |
| 3 | Order consumer + mapper + refusal matrix | `make e2e`, `make requester`, `make rejection` |
| 4 | Result correlator + progress tracker | `make results`, `make panel`, `make corrections`, `make progress`, `make collection` |
| 5 | Catalogue sync + OpenELIS REST client | `make catalogue-test` |
| 6 | Ops surface (dead letters, reconciliation, retention, export monitor, gauges) | `make monitoring`, `make negative`, `make auth` |
| 7 | Shutdown drain, hot-reload polish, `make auth` re-run under Redis outage | `make negative` mTLS block, `make auth` |
| 8 | Delete `services/Bridge`, `git mv`, repoint ~40 doc refs, README divergences section (F3/F5), optionally simplify D3 | Full sweep, 355 |

**How 2a tests without a cutover** (answers "incremental suites?"): a
throwaway compose override runs the Node image as a *second* container named
`bridge-node` on the `integration` network with `../certs:/certs:ro` — the
`bridge` name, Kong, and OpenELIS stay untouched. Prove the handshake from
inside the network, then remove the override. A path-splitting proxy is not
worth its complexity beyond this; from 2b on, switch-and-revert is the
mechanism, and the phase-1 technique (run locally against the live DB, diff
field-for-field) remains the inner loop. One caution for local runs from 2b on:
the poll endpoint *claims leases* — point write-path testing at a clone of
`bridge_sandbox`, not the live one, while the .NET bridge still serves.

**Between phases the compose build context reverts to `services/Bridge`**
unless the just-gated suite set is green on Node. The sandbox is a showcase
others may demo at any moment; it stays fully functional between sessions.

**What to cut if it must ship sooner: nothing.** The acceptance criterion is
355 passing checks; every phase exists because a suite pins it. The only
honest lever is the one already taken — order flow (2–4) lands before
catalogue sync and ops (5–6), so the clinically meaningful path works
earliest.

## Ground rules confirmed kept

No test in `scripts/` was touched; `services/Bridge` was not modified; nothing
in `services/bridge-node` was changed by this review. Every claim above names
the file or the live output it was verified against.
