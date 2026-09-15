# Security posture

What is protected, how, and — more usefully — what is not.

This describes the sandbox as it stands. It is written so that someone promoting
it to production can tell at a glance which controls are real, which are
placeholders, and which are absent for a reason that will not go away.

> **Re-verified against the running system on 2026-09-15.** Claims about
> OpenELIS's own behaviour were read from the deployed bytecode of 3.2.2.0 and
> its live configuration. Two things this pass corrected are marked in place:
> the `BasicAuthInterceptor` gate in §3, which was stated backwards, and the
> certificate expiry in §3 and §9, which nothing had noticed.

---

## 1. The shape of the problem

Three surfaces, and they cannot be treated alike:

| Surface | Callers | Control |
|---|---|---|
| `/fhir` on the bridge | OpenELIS | **Mutual TLS**, peer pinned to one certificate. A token of its own is not something OpenELIS has — see §3 |
| `/patients`, `/lab-orders`, `/test-catalogue` | clinicians via the browser | **User token** from IAM, verified and checked for revocation — §4 |
| `/internal/*` on the HIS | the bridge | **Service key** in `x-internal-api-key` — §5 |
| `/ops/*`, `/catalogue/sync` on the bridge | operators, `make` targets | **Operator token or user token**, fail-closed — §6 |
| `/admin/catalogue/refresh` on the HIS | the deployment | **Operator token**, fail-closed — §6 |

Four different controls, because there are four different kinds of caller. The
distinction that matters is not read-versus-write but *who is asking*, and what
that caller is able to prove: a clinician has an identity worth auditing, the
bridge is a service and has no user to be, and OpenELIS can prove itself with a
certificate but has no credential of its own to carry.

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

## 3. Why the FHIR endpoint has no token — and how it is secured instead

This is the part most worth reading. The obvious criticism — "the FHIR endpoint
is unauthenticated" — *was* correct, and the obvious fix genuinely does not
exist. The fix that does exist is a layer lower, and the distinction is the
whole lesson.

**OpenELIS 3.2.2.0 has no credential of its own to present to a remote FHIR
source.** That is a narrower statement than this section used to make, and the
narrowing is the point — see the correction note below.

**1. There is no configuration key for one.** `FhirConfig` declares property
placeholders for the local store and the client registry, but for the remote
source it declares only the URI and the identifier:

```
${org.openelisglobal.fhirstore.username:}     ${org.openelisglobal.fhirstore.password:}
${org.openelisglobal.crserver.username:}      ${org.openelisglobal.crserver.password:}
${org.openelisglobal.remote.source.uri:}      ← no username, no password
```

**2. The client it builds for us reuses the LOCAL store's credentials, or
none.** `FhirUtil.getFhirClient(String url)` — the overload
`FhirApiWorkFlowServiceImpl` calls to reach the bridge — is not gated on the
target at all:

```java
IGenericClient client = fhirContext.newRestfulGenericClient(url);
if (!GenericValidator.isBlankOrNull(fhirConfig.getUsername())) {
    client.registerInterceptor(
        new BasicAuthInterceptor(fhirConfig.getUsername(), fhirConfig.getPassword()));
}
```

`getUsername()` resolves `org.openelisglobal.fhirstore.username`. So OpenELIS
**will** send HTTP Basic to whatever remote FHIR source it is pointed at — using
the credentials of its own local HAPI store. In this deployment those are empty,
so nothing is sent.

> **Correction.** This section previously said the `BasicAuthInterceptor` is
> attached *only* when the URL equals `getLocalFhirStorePath()`, and therefore
> never to us. The bytecode says the opposite: in `FhirConfig` the equality test
> **skips** the interceptor for the local store, and in `FhirUtil` there is no
> URL test at all. The conclusion below is unchanged, but it rests on a
> different fact, and the old one would have misled anyone designing around it.

So a credential on `/fhir` is *technically* reachable — and still the wrong
control:

- it is **HTTP Basic**, not a bearer token;
- it is the **same secret as the local FHIR store's**, so it cannot be scoped to
  the bridge, rotated separately, or revoked without also cutting OpenELIS off
  from its own store;
- it would be sent to **every** remote FHIR client OpenELIS builds.

A shared credential spanning two trust domains is weaker than the transport
control that already works. `FhirUtil` does carry a
`getFhirClient(url, token)` overload that registers a `BearerTokenAuthInterceptor`
— but nothing in the remote-source path calls it, and no property feeds it.

The result push arrives over a FHIR `Subscription`. Its channel headers *are*
populated by `RegisterFhirHooksTask` — with the site name and site code, not
credentials — and there is no property to add an `Authorization` header.

So requiring a token on `/fhir` would not secure the integration. Modifying
OpenELIS is out of scope by standing constraint: it is the accredited component,
and changing it is what would actually put the laboratory's certification at
risk.

**The first answer was an origin allowlist.** `BRIDGE_FHIR_ALLOWED_PEERS` named
the OpenELIS containers, the bridge resolved them to addresses, everything else
got 403. It closed a real hole — anything else on the network could previously
inject a fabricated `DiagnosticReport`, which is a fabricated patient result —
but it authenticates a *network location*, not a node, and IHE ATNA requires the
latter.

It is still in the code, and still runs on the plaintext port. It is no longer
the control on the live path. What replaced it is below.

### Mutual TLS: what it is now, and why it needed no OpenELIS change

**The origin allowlist is no longer the control on this hop.** OpenELIS reaches
the bridge on a separate port that will not complete a TLS handshake without a
client certificate, and the bridge pins that certificate to exactly one peer.

The surprise is how little it took. **OpenELIS has always presented a client
certificate on every FHIR call** — nothing had ever asked it for one. Three
facts, read from the deployed webapp:

| | |
|---|---|
| `common.properties` — which this repository renders | sets `server.ssl.key-store` and `server.ssl.trust-store` to the certgen stores |
| `org.openelisglobal.config.HttpClientConfig` | builds the shared Apache `HttpClient` with `loadKeyMaterial(keystore)` **and** `loadTrustMaterial(truststore)` |
| `FhirConfig` | hands that client to every FHIR client it creates — the remote-source poll and the subscriber push included |

So the earlier claim in this section — that origin restriction was *"the
strongest control available without modifying OpenELIS"* — **was wrong**. Mutual
TLS was equally available, and it is what ATNA actually asks for. The mistake
was assuming that a system which cannot send a *bearer token* also cannot prove
its identity. Those are different layers.

**What changed, in full:**

1. A small CA is created, the bridge is issued a server certificate for
   `bridge.openelis.org`, and OpenELIS's certificate is **exported** from
   OpenELIS's own truststore.

   All three happen inside `make up`, and the split matters. The first two need
   nothing running, so `make config` does them before the stack starts. The
   third cannot — OpenELIS's certificate does not exist until certgen has made
   it — so a one-shot container (`oe-peer-cert`) reads it out of the volume once
   certgen exits, and the bridge waits for that one-shot before it starts.

   Getting this wrong is what a first attempt did: both loads happened while the
   bridge's host was being built, and a missing file threw. On a fresh clone
   there is no `certs/` directory, so the bridge crashlooped and no order ever
   reached the laboratory. The certificates are now read **per handshake**
   instead — which also means replacing one takes effect without a restart.
2. One `keytool -importcert` adds our CA beside certgen's entry, which is left
   untouched. This is the only change to anything OpenELIS reads, and it is the
   step its own installation guide describes: *"build a truststore containing
   the peer's certificate"*.
3. `BRIDGE_FHIR_BASE` becomes `https://bridge.openelis.org:8443/fhir`.

No image, no code, no schema, no database. Set `BRIDGE_MTLS_ENABLED=false` and
everything reverts to the previous behaviour, which is how to bisect a fault:
if it survives that, it is not TLS.

**The bridge never holds OpenELIS's private key.** It stores only the public
certificate, so it can recognise OpenELIS and cannot impersonate it.

**The peer is pinned, not merely CA-trusted.** Exactly one machine may ever
connect, so "is this that machine" is the question worth asking. `make negative`
proves the difference: a certificate freshly signed **by our own CA** is still
refused.

> **Pinning replaces chain validation, and that includes expiry.** The listener
> runs `requestCert: true, rejectUnauthorized: false` and compares the peer's
> DER bytes to the pinned copy in `secureConnection`. A byte comparison has no
> opinion about `notAfter`.
>
> This is not theoretical here. OpenELIS's shipped client certificate
> (`CN=localhost`, I-TECH's default) **expired on 2026-07-23** and the
> integration has kept working since. With `rejectUnauthorized: true` the real
> peer would have been refused on 24 July and every order would have stopped —
> while every impostor in `make negative` would still have been refused
> correctly, so the suite would have stayed green.
>
> The trade is deliberate and it is the right one for a sandbox pinned to a
> single peer. It is **not** right for a deployment that has a PKI: there,
> validate the chain *and* pin. Tracked in §9.

### Two things this exposed

**The traffic was not on the network everyone believed it was.** Docker resolves
a plain container name to its address on *one* of the networks the two
containers share, and it was choosing `oe-data-net`. So FHIR traffic between
OpenELIS and the bridge had been crossing the **data** network, not
`integration` — the boundary was true of network *membership* but not of the
packets. The fix is incidental to TLS and worth copying: the bridge's alias
`bridge.openelis.org` exists **only** on `integration`, so the name itself pins
the route.

**A weaker check can veto a stronger one.** Both controls were kept at first —
certificate *and* allowlist. Turning it on produced a successful handshake
followed by a 403, because the allowlist resolved the peer to its address on the
other network. That is not defence in depth; it is a second thing that can fail,
guarding a door already locked better. On the mutually authenticated port the
certificate is now the only check.

### What is still missing here

`bridge_fhir_requests_total{transport="mtls"|"plaintext"|"loopback"}` counts how
each FHIR request actually arrived, because a setting can say mutual TLS is on
while nothing uses the port. **`transport="plaintext"` above zero in a real
deployment means a caller is still using the old address.**

Still absent: certificate **rotation** — our own are ten-year certificates with
no renewal process, and OpenELIS's has already expired without anything noticing
(§9) — any **CRL or OCSP**, since revocation checking is off because a
two-member private CA publishes neither, and the ATNA **audit** half, §9.

---

## 4. User authentication

The clinical API is behind the estate's own scheme, implemented the way the
estate implements it rather than the way this repository would have chosen. The
point of a reference implementation is that a developer can copy from it.

### The pattern

IAM signs a token at login and writes the session to Redis. Every other service
only verifies:

```
POST /api/auth/login        IAM: check password
                            → jwt.sign(payload, JWT_SECRET, { expiresIn: '1d' })
                            → HSET user:{usr_id} token <jwt>  |  EXPIRE 24h

GET  /patients/search       this service: verify the signature
                            → HGET user:{usr_id} token
                            → equal? serve.  missing or different? 401.
```

The claims are IAM's, unchanged: `usr_id`, `usr_name`, `usr_full_name`,
`group_names`, `group_ids`, `business_unit_ids`.

**Why both halves.** The signature proves the token was issued by IAM and has
not been altered. It cannot express *"this person logged out four minutes ago"* —
a signed token stays valid until it expires, whatever happens in between. The
Redis session is what makes a logout take effect now, and a session hash that a
password change deletes is what makes a compromised account recoverable.

The sandbox has no IAM, so `make token` performs IAM's two write steps and
nothing else. It is not a login: no password, no user table, no lockout.

```
make token                                    # sign in as a default user
make token USER=7 NAME=dr.reed GROUPS=lab-orders,lab-ops
```

### Three differences from the estate's copy

Each is a small change to `patient-service`'s middleware, and each is there for
a reason that showed up in this sandbox.

**1. The algorithm is pinned.** `jwt.verify(token, secret, { algorithms: ['HS256'] })`.
Without the third argument the library accepts any algorithm the key can verify.
For a string secret that is the HMAC family only, so this is *not* the classic
algorithm-confusion hole — but it costs one line and removes the question for
whoever later changes the key type.

**2. The outage is logged at its edges, not per request.** The estate's version
logs a warning inside the per-request catch block. An outage is precisely when
traffic does not fall, so at any real rate that is thousands of identical lines
a minute, on a Kafka topic shared with every service in the estate — the same
failure mode the framework log filter exists to prevent. One line when Redis
goes, one when it returns.

**3. Whether the session was verified is carried forward.** `req.user.degraded`
and a metric, `auth_revocation_checks_total{result="degraded"}`. Without it
there is no way to answer, afterwards, which requests were served without a
revocation check — the requests succeed, so no error rate moves.

### When Redis is down

The estate's choice, kept: **verify the signature, skip the revocation check,
serve the request**. A cache outage does not stop a hospital ordering blood
tests. The cost is real and worth stating — a token revoked before the outage
works during it — but the alternative is worse.

What did have to change is that the estate's fallback **does not actually fall
back**:

```ts
// services/his-api/src/config/redis.ts
enableOfflineQueue: false,
```

ioredis, by default, *queues* commands issued while the connection is down and
replays them when it returns. Combined with a degraded-mode catch block that
produces the opposite of what the catch block intends: instead of failing fast
and continuing, every request waits in the offline queue. The fallback is never
reached, because the command never errors — it just does not finish.

With the queue off, a command issued while disconnected rejects in
microseconds. `make auth` asserts the clinical API answers **in under five
seconds** with Redis stopped, which is the assertion that would fail on the
estate's current settings.

The same trap exists in other clients under other names, and the bridge hit it
while it was still a .NET service: StackExchange.Redis's
`ConnectionMultiplexer.Connect` throws when Redis is unreachable unless
`AbortOnConnectFail = false`, and a service that catches that throw ends up
holding no connection at all — serving happily, silently never checking
revocation again, until someone restarts it. Worth knowing when connecting any
new service to this Redis.

### What HS256 costs

Two properties follow from the estate's choice of a shared symmetric secret, and
neither can be fixed in a consuming service:

**Every verifier is also an issuer.** The key that checks a signature is the key
that makes one. Any service holding `JWT_SECRET` — and they all do, because they
all verify — can mint a token for any user, with any groups. `mint-token.sh`
demonstrates this by signing inside the `his-api` container: it is not a
shortcut taken for the sandbox, it is what the design permits.

**Nothing scopes a token to one service.** IAM's payload has no `aud` claim, so
a token minted for the appointment service is equally valid at the laboratory
API and at the bridge. There is nothing to validate, which is why
`aud` is not verified in `ops-access.ts` — turning that on would reject
every real token.

**The fix belongs in IAM, not here.** Sign RS256: IAM holds the private key,
every other service gets the public one and can only verify. Add `aud`, and let
each service require its own. Both are changes to one service, and neither
breaks a consumer that already ignores those fields.

### Two services in the estate verify nothing

Found while reading the estate's middleware, and worth acting on:

| Service | Line | What it does |
|---|---|---|
| `HIS-org-setup-service` | `src/middleware/auth.middleware.ts:31` | `jwt.decode(token)` |
| `file-upload-service` | `src/middleware/auth.middleware.ts:32` | `jwt.decode(token)` |

`jwt.decode` **does not verify the signature and does not check expiry.** It
base64-decodes the payload and returns it. `patient-service` was corrected —
the comment there still reads *"CRITICAL SECURITY FIX: verify the signature, do
not just decode it"* — but the other two were not.

What saves them today is the Redis lookup two lines later: a forged token for
`usr_id: 1` is compared against the real session for user 1 and does not match,
so the request is refused. That is an accident of ordering, not a control. It
fails the moment either service adds the degraded-mode fallback
`patient-service` already has — at which point a token anyone can write, for any
user, is accepted whenever Redis blinks.

Expiry is a live problem there regardless: `decode` ignores `exp`, so an expired
token keeps working until the 24-hour session hash expires, however short
`JWT_EXPIRE` is set.

**The fix is one word in each file**, `decode` → `verify`, plus the secret and
the algorithm.

There is also a hardcoded fallback secret in
`file-upload-service/src/middleware/file-auth.middleware.ts:8`:

```ts
const secret = process.env.SIGNING_JWT_SECRET || 'your-secret-key';
```

If that variable is ever unset, download links are signed and verified with a
string that is in the repository. It should fail closed instead.

### Sessions live in memory

The estate's Redis runs without persistence, so a Redis restart signs out every
user in the hospital at once. Tokens stay signed and valid, but no session hash
exists to match them against, so every request is refused until each user logs
in again. `make auth` demonstrates it: after a Redis restart the suite must sign
in again to continue.

Worth knowing before Redis is restarted during a working day. If that is not
acceptable, the answer is `appendonly yes` on the session instance — the session
data is small and rewriting it on restart costs nothing compared to a
hospital-wide logout.

---

## 5. Service-to-service

The bridge calls `/internal/*` on the HIS service directly, and presents
`x-internal-api-key` — the header the estate's gateway already uses for internal
calls.

**Why not a user token.** The bridge is not a person. Giving it one would mean
inventing a user for it, storing that user's password somewhere, and producing
audit records naming a clinician who did nothing.

**Why a credential at all, when the endpoint is not routed by Kong.** The
network boundary answers "can the internet reach this" — no; Kong has no route
to `/internal/*`. It does not answer "can everything already inside the sandbox
network read every patient in the hospital", and that list includes Kong, the
frontend container and Redis. The key is what answers the second question.

Same three properties as the operator tokens: fail-closed when unset,
fixed-time comparison, never logged.

**Not a substitute for the boundary — an addition to it.** If the key leaks, the
attacker still has to be on the sandbox network to use it.

---

## 6. The administrative surface

`/ops/*` and the catalogue sync sit behind `BRIDGE_ADMIN_TOKEN`;
`/admin/catalogue/refresh` on the HIS sits behind `HIS_ADMIN_TOKEN`.

Three properties are deliberate:

**Fail closed.** An unset token means the endpoint refuses *everything* (503),
not that it is open. The opposite default is how these get forgotten: it works
in testing and is discovered in production by someone who was not looking for
it.

**Fixed-time comparison.** `crypto.timingSafeEqual`, not `===`, in both
services. A plain string compare returns sooner the earlier it finds a
difference, which hands the token over one character at a time to anyone patient
enough to measure. Length is checked first, because `timingSafeEqual` throws on
a length mismatch rather than returning false.

**The token is never logged**, at any level. A rejected credential is often a
correct credential for somewhere else.

**Why `/ops/*` and not just the writes.** `/ops/orders` and `/ops/dead-letters`
only read — but what they read is which orders are outstanding and which
failed, for named patients. That is a description of real people's care, and it
does not become public because it is a GET.

**What is deliberately left open**, and must stay that way:

- `/health` and `/metrics` on both services — a health check that can fail
  authentication reports an outage that is not happening, and takes the service
  out of Kong's rotation for a reason that has nothing to do with its health
- `GET /catalogue` on the bridge — the cached test menu, read by the HIS
  service. It is the laboratory's list of orderable tests and contains no
  patient data at all; the endpoint that *changes* it is behind a token

**What used to be on that list and no longer is.** `GET /test-catalogue` on the
HIS was argued here as necessarily open, on the grounds that locking the
ordering screen out of its own menu is a worse failure than leaving the menu
readable. That argument was about a screen with no credential to present. The
screen now holds a user token for everything else it does, so the premise is
gone, and the menu is behind the same door as the orders placed from it.

`/internal/*` has moved the other way, from "governed by network membership" to
network membership **and** a service key — §5.

---

## 7. Data that does not grow for ever

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

## 8. Durability of the message bus

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

## 9. What is still open

Ordered by how much it would matter in a hospital.

**A refusal cannot be distinguished from a failure — and this one can reach a
clinician.** OpenELIS sets `Task.status = rejected` both when the laboratory
genuinely declines an order **and** when it hits an internal storage or indexing
error. The two are identical on the wire. Nothing in this repository can separate
them, because no second field carries the reason.

The consequence is not operational, it is clinical: the HIS can tell a doctor
*"the laboratory refused this test"* when the laboratory in fact accepted it and
is working on it. A doctor who believes a test was refused may re-order it, or
worse, proceed without it.

Until upstream separates the two — filed as
[defect 01](upstream-issues/01-task-poll-not-idempotent.md) — a HIS built on this
should present a rejection as *"this order did not complete and needs review"*
rather than as a definite refusal. That wording costs nothing and is true in both
cases.

**~~Nothing watches, and nothing wakes anyone.~~ Half fixed: something watches
now, nothing wakes anyone yet.** `/metrics` had been exposed in Prometheus
format from the beginning and nothing read it — metrics nobody scrapes are a
file the process writes to itself, and the failure modes they describe stayed
exactly as invisible as before the instrumentation was added.

There is now a Prometheus container scraping the bridge, his-api and Kong, and
seven rules in [`monitoring/alerts.yml`](../monitoring/alerts.yml) covering
precisely the four quiet failures listed here before — orders undelivered,
`dead_letters` growing, the catalogue sync ageing, OpenELIS not polling — plus
service-down and the result consumer. The bridge grew four gauges to make them
expressible, because none of it was measurable from request counts:
`bridge_oldest_requested_task_age_seconds`, `bridge_dead_letters_total`,
`bridge_catalogue_age_seconds`, `bridge_last_poll_age_seconds`.

**What is still missing is the last hop: routing.** No Alertmanager, so nothing
pages anybody — `make alerts` shows what is firing to whoever thinks to look.
That is a deliberate stopping point rather than an oversight: who is on call and
how they are reached is a hospital's decision, and a sandbox that shipped one
arbitrary answer would teach it as though it were the answer.

Three things this exercise established that are worth carrying into the real
deployment:

* **A gauge that has never been refreshed is not zero, it is absent.**
  Every Prometheus client registers a gauge at `0` the moment it is
  constructed. An early version of the refresh loop threw on every pass, so all
  four sat at zero and read as "nothing stuck, no dead letters, catalogue
  fresh" — the most alarming state publishing the most reassuring numbers, with
  every alert satisfied by a component that had never queried the database. The
  bridge now **does not construct them** until a refresh has returned real
  values (`gauges ??= createGauges()`), so a broken collector yields no series
  at all rather than four reassuring zeroes.
* **A rule can be `health: ok` and incapable of firing.** Prometheus validates
  that an expression parses, not that the metric exists. Rename a gauge and its
  alerts go silent for ever behind a green rules page. `make monitoring` asserts
  every metric named by every alert still resolves.
* **Do not bind-mount single config files.** Mounting `alerts.yml` directly
  served Prometheus a *truncated* copy: six of seven rules loaded, all six
  healthy. A missing alert is the exact failure this component exists to
  prevent, and the mount introduced it. Mount the directory.

The remaining production gaps — high availability, real secrets, backups with a
rehearsed restore, certificates from your own PKI — are collected in
[integration-guide.md](integration-guide.md#from-integration-to-production) rather
than duplicated here, so there is one list to keep current.

**No audit trail in the form an assessor expects.** This is the gap most likely
to be missed, because the system does not feel like it is missing anything: the
HIS writes an audit row for every order transition (`his.lab_order_events`), the
bridge keeps `order_tracking` and `dead_letters`, and both services put
structured application logs on the estate's shared Kafka topic.

None of that is what IHE ATNA means by an audit trail. ATNA requires **security
audit events** — who accessed which patient's data, from where, and whether it
succeeded — recorded in the RFC 3881 / DICOM Supplement 95 schema and forwarded
to a central **Audit Record Repository** over syslog with TLS. What exists here
is *clinical* history plus operational logging. Neither answers "which user read
this patient's results last Tuesday", which is the question an audit trail is
kept to answer.

Two things make this cheaper than it sounds now that authentication exists: the
identity to record is already on `req.user`, and the transport to a repository
is the same shipping path the log topic already uses. It is a schema and a
destination, not new plumbing.

**~~`orderingProvider` is still free text.~~ Fixed.** The order is now attributed
to the verified token: `ordering_provider_id` holds the caller's `usr_id` and
`ordering_provider` their `usr_full_name`. Supplying the field in the request
body is **refused with a 400**, not ignored — zod strips unknown keys, so
dropping it from the schema silently would have let a caller's value vanish
while the request succeeded and the order named somebody else. That is a worse
failure than an error, because nothing announces it.

Three things this settled that were not obvious at the outset:

* **The database held two answers to one question.** `his.audit_events` named
  the actor from the token; `his.lab_orders.ordering_provider` named whoever was
  typed. Nothing reconciled them, so every audit row was only as good as a text
  box.
* **It travelled.** The bridge derived the FHIR Practitioner identity from a
  hash of the display name, which made every spelling of a clinician's name a
  different practitioner in the laboratory's own provider records —
  permanently, since a laboratory report prints the requesting clinician. It is
  now keyed on the **clinician** — `mlh_his_hcp_health_care_provider.id`, not
  the login account — and the Practitioner carries it under
  `http://openelis-global.org/hcp_id`, with the licence number as a second
  identifier. §4 of the integration guide explains why the account is the wrong
  key: it is nullable, non-unique, and absent for a visiting consultant.
* **The form was the real risk.** The field was prefilled. An order could be
  attributed to a colleague by nobody doing anything at all — which is the
  clinician who then receives the result, is telephoned about a critical value,
  and is accountable for acting on it. The frontend now displays who is signed
  in and offers nothing to edit.

**Ordering on behalf of another clinician is not supported, and must not be.**
This is a rule of the HIS, not a limitation of the sandbox: the doctor logs in,
conducts the visit, and places the order themselves. Nobody orders for anybody
else.

That makes the token the *whole* answer rather than most of it. There is no
second field to add, no "on behalf of" to reconcile, and no case in which the
signed-in user is not the ordering clinician — so any future code that lets the
two differ is a defect, not a feature. Recording the ordering provider from
anywhere except the verified session would be reintroducing the problem this
section describes.

**Recording a bedside draw is attributed but not separately authorised.**
`POST /lab-orders/{orderNumber}/collection` sits behind the same user token and
`LAB_ORDER_GROUP` check as placing an order, and is audited as an update
(`laborder.collect`, `U`) with the order in the resource field. That is the
right shape for the sandbox, and it is not the right shape for a hospital:
drawing blood is a **nursing** act, and a real estate would give it its own
group rather than letting anyone who can order a test also assert that a
specimen was drawn.

Note what the assertion is worth. The collection time it records travels to the
laboratory, is pre-filled onto the accessioner's screen, and ends up shaping a
clinician's judgement of whether a result still describes the patient. It is
refused when the order is not `AWAITING_COLLECTION`, when the order is an
outpatient one, and when the timestamp is in the future — but nothing verifies
that the person recording it is the person who held the needle, and nothing
could. **The control here is attribution, not prevention:** `his.audit_events`
names who said it, and `lab_order_events` keeps a `SPECIMEN_COLLECTED` row with
the time and correlation id.

**Authorisation is one group name per surface.** `LAB_ORDER_GROUP` and
`BRIDGE_OPS_GROUP` are membership checks, not permissions. The estate does real
authorisation with Casbin against policies IAM owns; a second, differently
shaped permission model in a reference service would be a worse example than an
obviously partial one. A service adopting this should call Casbin.

**Nothing enforces business-unit scope.** The token carries
`business_unit_ids`, and no query filters by it. A clinician authenticated for
one hospital can read patients from another.

**HS256 and no `aud`** — §4, "What HS256 costs". The fix is in IAM.

**TLS covers the OpenELIS hop and nothing else.** Bridge ↔ OpenELIS is now
mutually authenticated TLS (§3). Every other hop inside the sandbox is still
plain HTTP: browser → edge → Kong → his-api, his-api → bridge, and both
services to Postgres, Kafka and Redis. Those carry patient data too. The
OpenELIS hop was ranked first because it crosses an organisational boundary and
was the one an assessor would open with — it is not the last of this work.

**No certificate rotation — and one certificate has already expired.**
OpenELIS's client certificate, the one the bridge pins, is I-TECH's shipped
default (`CN=localhost`) and its `notAfter` was **2026-07-23**. It is still in
use, because pinning compares DER bytes and a byte comparison cannot read a
date (§3).

Nothing is broken today and nothing will break on its own, which is exactly the
problem: the condition is invisible, and it will stay invisible until someone
turns on chain validation and discovers the integration stops.

**It cannot be fixed from this repository, and the obvious attempts do not
work.** Tested on 2026-09-15:

| Attempt | Result |
|---|---|
| `make certs FORCE=true` | Regenerates **our** CA and bridge certificate, then **re-exports the same expired peer certificate** — `init-mtls.sh` exports OpenELIS's cert from its truststore rather than issuing it. No change, and now the CA has rotated for nothing. |
| Delete the certgen volumes and `make up` | Also no change. The certificate came back **byte-identical**, same `notBefore` to the second. |

The reason is that `itechuw/certgen` does not generate anything. Its name is
misleading: the image **ships prebuilt keystores baked into its layers**, dated
`Jul 23 2025`, and the container copies them into the volumes. Pinned by digest,
as it should be, that makes the certificate a fixed property of the image:

```
$ docker run --rm --entrypoint sh itechuw/certgen@sha256:e27a81… -c 'ls -la /etc/openelis-global'
-rwxrwxrwx 1 root root 2589 Jul 23  2025 client_facing_keystore
-rwxrwxrwx 1 root root 2589 Jul 23  2025 keystore
-rwxrwxrwx 1 root root 1366 Jul 23  2025 truststore
```

So the real options are upstream's or your own:

1. **A newer certgen image.** Moves the expiry; does not remove the problem,
   since whatever it ships also has a fixed date.
2. **Supply OpenELIS's keystore yourself**, from your PKI, and mount it in place
   of the certgen volume. This is configuration rather than a code change to the
   accredited component, and it is what a real deployment should do anyway —
   see §9.
3. **Leave it, knowingly.** Which is the current state, and is defensible only
   because the peer is pinned by bytes.

**Whichever you choose, do not turn on `rejectUnauthorized` first.** With the
peer certificate expired, strict validation refuses the real OpenELIS and the
laboratory stops receiving orders — while every impostor in `make negative` is
still refused correctly, so the suite stays green and tells you nothing.

The bridge's own certificates are valid for ten years with no renewal path. Ten
-year certificates are what you issue when you have no rotation process, and
they are how an outage arrives with no warning nine years later. A real
deployment wants short-lived certificates from its own PKI, chain validation
*and* pinning, and a documented rotation procedure that accounts for the
truststore being read once at startup.

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

## 10. What is tested

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
- the order ledger is refused without a token, and its window is clamped at both
  ends. What it reports is which patients' orders did not complete, which does
  not become public because it is a `GET`
- the sweep reports the windows *this deployment configured*, which catches a
  variable added to `.env` and never wired through compose

In `make auth`, thirty-odd assertions across six groups. The ones worth naming:

- **a token signed with a different secret is refused** — the case
  `jwt.decode` accepts, and two estate services still use it (§4)
- **a correctly signed token whose Redis session was deleted is refused**, and
  told *"Session ended or token revoked"* rather than *"invalid token"*: the
  distinction between a bad token and an ended session
- **a second sign-in for the same user ends the first session** — one `token`
  field per user, so signing in on a phone signs out the desktop
- with Redis stopped: **the clinical API still answers**, **in under five
  seconds**, and **a revoked token is accepted**. The last of those is not a
  bug being tolerated; it is what degraded mode costs, asserted rather than
  footnoted
- **ten requests during the outage add no further log lines**, asserted
  causally — sampling the log tail would test what the service did last week
- **the bridge enforces revocation again once Redis returns**, having first
  reached for Redis *during* the outage. That is the assertion that fails if
  `AbortOnConnectFail` is left at its default
- `/internal/*` refuses no key and a wrong key, and **a user token is not a
  service key**
- the bridge's `/ops` takes either the operator token or a user token in
  `BRIDGE_OPS_GROUP`, refuses one without the group with **403 rather than
  401**, and **names the user in the log**

In `make smoke`: the search cap, the `_count` clamp, the topic replication
factor and `min.insync.replicas`.
