# Security posture

What is protected, how, and — more usefully — what is not.

This describes the sandbox as it stands. It is written so that someone
promoting it to production can tell at a glance which controls are real, which
are placeholders, and which are absent for a reason that will not go away.

---

## 1. The shape of the problem

Three surfaces, and they cannot be treated alike:

| Surface | Callers | Control |
|---|---|---|
| `/fhir` on the bridge | OpenELIS | **Origin restriction.** A credential is impossible — see §3 |
| `/ops/*`, `/catalogue/sync`, `/admin/catalogue/refresh` | operators, `make` targets | **Bearer token**, fail-closed |
| `/patients`, `/lab-orders`, `/test-catalogue` | clinicians via the browser | **None yet** — see §7 |

The middle row is ours on both ends, so it gets real authentication. The top
row is constrained by what OpenELIS can do. The bottom row is the largest
remaining gap and needs per-user identity, not a shared token.

---

## 2. Credentials

`.env` is no longer committed. `.env.example` holds the *shape* of the
configuration and is; `make secrets` mints the values into `.env`, which is
gitignored and written mode 600.

```
make secrets      # 8 random secrets, then lists what you must set by hand
```

Two values cannot be generated, because they belong to OpenELIS rather than to
this repository: the seeded admin password, and the service account the bridge
reads the catalogue with. `init-secrets.sh` leaves them as `__SET_ME__` and
prints them, rather than letting the stack come up and fail somewhere less
obvious.

**What this does not do.** The old credentials are still in git history. For a
sandbox whose passwords were `postgres_admin_pw` and are printed in the README
that is not worth a history rewrite — but it means the fix is "no *new* secret
can be committed", not "the repository is clean". If a real credential is ever
added and then removed, that is a different problem needing a different tool.

The bridge holds an OpenELIS account. Give it a **read-only** one: everything
the bridge does over REST is a GET, and a credential that lives in a container's
environment should be able to do no more than the container needs.

---

## 3. Why the FHIR endpoint has no token

This is the part most worth reading, because the obvious criticism of this
system — "the FHIR endpoint is unauthenticated" — is correct, and the obvious
fix does not exist.

OpenELIS 3.2.1.11 **cannot present a credential to a remote FHIR source.** Two
independent facts in the shipped webapp establish it. Both were read out of the
deployed classes, not inferred from documentation:

**1. There is no configuration key to put one in.** `FhirConfig` declares
property placeholders for the local store and the client registry, but for the
remote source it declares only the URI:

```
${org.openelisglobal.fhirstore.username:}     ${org.openelisglobal.fhirstore.password:}
${org.openelisglobal.crserver.username:}      ${org.openelisglobal.crserver.password:}
${org.openelisglobal.remote.source.uri:}      ← no username, no password
```

**2. The one auth interceptor it registers is gated on the target.** The
`BasicAuthInterceptor` is attached only when the URL being called equals
`getLocalFhirStorePath()`. The bridge is not the local store, so the header is
never attached to a call made to it.

The result push arrives over a FHIR `Subscription`, whose channel *does* support
headers in the R4 model — but `RegisterFhirHooksTask` exposes no property to
populate them either.

So requiring a token on `/fhir` would not secure the integration. It would end
it: OpenELIS would poll, receive 401, and no order would ever reach the
laboratory. Modifying OpenELIS is out of scope by standing constraint — it is
the accredited component, and changing it is what would actually put the
laboratory's certification at risk.

**What was done instead.** `/fhir` is restricted by origin:
`BRIDGE_FHIR_ALLOWED_PEERS` names the OpenELIS containers, the bridge resolves
them to addresses, and everything else gets 403.

This is genuinely weaker than authentication and should be read that way.

| Removed | Not removed |
|---|---|
| Any *other* container on the sandbox network — the HIS service, the frontend, Kong, Redis — injecting a fabricated result or reading the order stream | An attacker who can spoof a source address on the Docker network |
| A misconfigured service accidentally writing to the FHIR endpoint | An attacker who has taken over an OpenELIS container |

The first column used to be wide open, and a fabricated `DiagnosticReport` is a
fabricated patient result. That is the gap this closes.

In production, put mutual TLS between the two containers at the proxy layer, or
an mTLS-terminating sidecar. That works without OpenELIS knowing anything about
it, which is exactly why it is the right answer here.

---

## 4. The administrative surface

`/ops/*` and the catalogue sync sit behind `BRIDGE_ADMIN_TOKEN`;
`/admin/catalogue/refresh` on the HIS sits behind `HIS_ADMIN_TOKEN`.

Three properties are deliberate:

**Fail closed.** An unset token means the endpoint refuses *everything* (503),
not that it is open. The opposite default is how these get forgotten: it works
in testing and is discovered in production by someone who was not looking for
it.

**Fixed-time comparison.** `CryptographicOperations.FixedTimeEquals`, not `==`.
A plain string compare returns sooner the earlier it finds a difference, which
hands the token over one character at a time to anyone patient enough to
measure.

**The token is never logged**, at any level. A rejected credential is often a
correct credential for somewhere else.

**Why `/ops/*` and not just the writes.** `/ops/orders` and `/ops/dead-letters`
only read — but what they read is which orders are outstanding and which
failed, for named patients. That is a description of real people's care, and it
does not become public because it is a GET.

**What is deliberately left open**, and must stay that way:

- `/healthz` on both services — a health check that needs a credential is a
  health check that reports unhealthy when the credential is wrong
- `GET /catalogue` on the bridge and `GET /test-catalogue` on the HIS — the
  read-only test menu. Locking the ordering screen out of its own menu is a
  worse failure than leaving the menu readable, and it is the failure this kind
  of change actually causes
- `/internal/*` on the HIS — governed by network membership, as it always has
  been. The bridge reaches it directly over `sandbox`; it is not routed by Kong

---

## 5. Data that does not grow for ever

Four bridge tables accumulated with traffic and nothing removed from any of
them. In this sandbox that is invisible; in a laboratory running a few thousand
results a day it is a database that grows until it becomes the outage — and it
is the database you would want to query while diagnosing one.

| Table | Window | Why that window |
|---|---|---|
| `received_resources` | 30d | a mirror kept so a late report can still be correlated |
| `processed_events` | 14d | duplicate suppression; useful only while redelivery is plausible |
| `export_status_checks` | 30d | health history, read when explaining an incident |
| `dead_letters` | 180d | failures a human has not dealt with — kept longest |

The windows differ because the data does. A single global "keep 90 days" would
either discard duplicate suppression while redelivery is still possible, or
hoard failures nobody will read.

Two rules hold across all of them:

- **Nothing unfinished is deleted, whatever its age.** An unprocessed resource
  is a result that has not reached the patient's record yet. Its age is not
  evidence that it never will.
- **`0` disables a sweep.** A laboratory under an audit hold cannot have its
  history swept because a default said 30 days.

`fhir_resources` is deliberately *absent* from the sweep. It is what OpenELIS
**reads** — an order it has not yet polled, a ServiceRequest it dereferences
when a late report arrives. Pruning it by age would delete the far side of a
conversation that is still going. It is bounded by the number of live orders,
not by time, so it does not belong in a time-based sweep.

```
make prune        # run the sweep now and report what it removed
```

---

## 6. Durability of the message bus

The producers already write with `acks=all` and idempotence enabled. That was
never the gap. The gap is that `min.insync.replicas=1` on a single broker means
"all replicas acknowledged" can mean "the one replica that happened to be up".

`KAFKA_REPLICATION_FACTOR` and `KAFKA_MIN_INSYNC_REPLICAS` are now deployment
parameters, applied to the data topics *and* to Kafka's own internal topics —
leaving `__consumer_offsets` at 1 while the data topics run at 3 moves the
single point of failure rather than removing it.

```
KAFKA_REPLICATION_FACTOR=3
KAFKA_MIN_INSYNC_REPLICAS=2
```

`min.insync.replicas` is applied with `--alter`, not `--create`, so raising
durability on an existing deployment is a restart rather than a topic rebuild.

**This is a parameter, not a fix.** The sandbox runs one broker and therefore
runs at 1/1. Three brokers is an operational change, and until it is made, a
broker failure loses orders. Nothing in the code has to change for it.

---

## 7. What is still open

Ordered by how much it would matter in a hospital.

**No per-user authentication on the clinical API.** Anyone who can reach the
edge can create a patient, place an order, and read any patient's results.
This is the big one. It needs real identity — OIDC against the hospital's
directory, with the clinician's identity carried through to `orderingProvider`
rather than accepted as a free-text field. A shared token is not the answer
here; the point is *which clinician*, and audit that can name them.

**No TLS inside the sandbox.** Bridge ↔ OpenELIS is plain HTTP
(`allowHTTP=true`). Patient results cross that hop in clear text. Terminating
TLS at the proxy is also where mutual TLS would go (§3), so these are one
piece of work.

**Self-signed certificates**, and `OE_REST_ACCEPT_ANY_CERT=true`. That flag
must be `false` anywhere real; it is configuration rather than an unconditional
bypass precisely so it can be turned off without a code change.

**Kong admin API on a published port** with no authentication
(`KONG_ADMIN_PORT`). Anyone reaching it can rewrite the routing.

**No rate limiting** on the clinical API. `request-size-limiting` is
configured; nothing bounds request *frequency*.

**The HIS holds a copy of results.** By design — OpenELIS remains the source of
truth and the HIS keeps a simplified projection. Worth stating plainly in a
security document: that projection is patient data at rest in a second place,
and it needs the same encryption, backup and access controls as the first.

---

## 8. What is tested

Access control is asserted on **status codes**, not response bodies. A refusal
that returns 200 with an error message in it passes any test that greps the
body, and is indistinguishable from success to every client.

In `make negative`:

- the sync is refused with no token, and with a wrong token
- the right token is allowed through
- the HIS catalogue refresh is refused with no token
- the deliberately-open endpoints are **still open** — the failure this kind of
  change actually causes
- a container that is not OpenELIS gets 403 from `/fhir/metadata` *and* from a
  result push
- OpenELIS itself still gets 200
- retention removes an aged, correlated resource and **keeps** an aged
  uncorrelated one — proved by ageing rows on both sides of the guard, because
  a sweep run against fresh data deletes nothing and passes whatever it is
  asserted against, including a sweep that is broken
- the sweep reports the windows *this deployment configured*, which catches a
  variable added to `.env` and never wired through compose

In `make smoke`: the search cap, the `_count` clamp, the topic replication
factor and `min.insync.replicas`.
