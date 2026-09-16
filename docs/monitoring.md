# Monitoring

What watches this integration, what each number means, and how to add to it.

This is the **reference**. If something is wrong *right now*, go to
[operations.md §5](operations.md#5-monitoring) instead — that is the
incident-response view, and it will not repeat itself here.

---

## 1. The idea in one paragraph

Every failure worth alerting on in this integration is **silent**. Nothing
errors, no container goes red, no request returns 500 — an order simply sits
there and nobody is told. That is the entry requirement for a rule here: if it
would already show up as a crash or a 500, it does not need an alert. Which is
why almost every rule reads a gauge measuring **how old** something is, rather
than a count of requests.

---

## 2. What is running

| | |
|---|---|
| **URL** | **http://localhost:9090** — no login, bound to your machine only |
| Container | `his-prometheus`, image `prom/prometheus:v3.1.0` |
| Config | [`monitoring/prometheus.yml`](../monitoring/prometheus.yml) |
| Rules | [`monitoring/alerts.yml`](../monitoring/alerts.yml) — seven |
| Scrape / evaluate | every **15 s** |
| Retention | **2 days**, capped at **512 MB** |

Two pages worth bookmarking:

- **/alerts** — what is firing
- **/graph** — paste a metric, press Execute

Retention is deliberately short. This runs beside a full OpenELIS on an 8 GiB
laptop, and it answers *"what happened yesterday"*, not *"what happened in
March"*. Long-term storage in production is a remote-write question, not a
bigger local disk.

### What it scrapes

| Job | Target | Label | Why |
|---|---|---|---|
| `bridge` | `bridge:8080` | `component: integration` | **the one that matters** — every rule but the service-down pair reads a gauge from here |
| `his-api` | `his-api:8080` | `component: his` | the result consumer |
| `kong` | `kong:8001` | `component: edge` | request rates at the edge; nothing alerts on it yet, wired so that adding an edge-latency rule needs no new plumbing |
| `prometheus` | itself | — | so a collector that is unwell can say so |

---

## 3. The metrics

### From the bridge

| Metric | Means | Sentinel |
|---|---|---|
| `bridge_oldest_requested_task_age_seconds` | age of the oldest order still waiting for the laboratory to collect it | **0** when none are waiting |
| `bridge_dead_letters_total` | failures that need a human | — |
| `bridge_catalogue_age_seconds` | time since the test menu was synced from OpenELIS | **-1** = never synced |
| `bridge_last_poll_age_seconds` | time since OpenELIS last asked for orders | **-1** until the first poll of this process |
| `bridge_fhir_requests_total{transport=}` | FHIR requests by how the connection was authenticated — `mtls`, `plaintext`, `loopback` | — |

### From his-api

| Metric | Means |
|---|---|
| `kafka_consumer_running` | **1** subscribed and receiving, **0** not. A service can be healthy, passing its Consul check, and not consuming — that happened on the first clean run of this stack |
| `auth_revocation_checks_total{result=}` | `result="degraded"` climbing means Redis is down and logouts are not taking effect |

Both services also expose `http_requests_total`, `http_request_duration_seconds`
and `in_flight_requests` in the estate's standard shape.

> **Why `-1` and not `0`.** For an *age*, zero is the healthiest possible
> reading. A catalogue that has never synced reporting `0` would read as "synced
> just now" — the least healthy state publishing the most reassuring number. So
> "never" is `-1`, and `CatalogueNeverSynced` matches on it exactly.

---

## 4. The seven rules

| Alert | Fires when | Held for | Severity |
|---|---|---|---|
| `OrderUndelivered` | `bridge_oldest_requested_task_age_seconds > 900` | 2m | critical |
| `LaboratoryStoppedPolling` | `bridge_last_poll_age_seconds > 300` | 2m | critical |
| `DeadLettersGrowing` | `bridge_dead_letters_total` grew in the last hour | 5m | warning |
| `CatalogueStale` | `bridge_catalogue_age_seconds > 3888000` (45 days) | 1h | warning |
| `CatalogueNeverSynced` | `bridge_catalogue_age_seconds == -1` | 15m | warning |
| `ServiceDown` | `up{component=~"integration\|his"} == 0` | 1m | critical |
| `ResultConsumerNotRunning` | `kafka_consumer_running == 0` | 2m | critical |

What each one means and what to do about it is the table in
[operations.md §5](operations.md#the-alerts-and-what-to-do-about-each).

Two of them are worth understanding together:

**`LaboratoryStoppedPolling` fires before `OrderUndelivered`** and is the more
useful of the two, because it does not need an order to exist. If OpenELIS has
stopped asking, you want to know at once — not fifteen minutes after somebody
happens to place an order.

**`OrderUndelivered` is also the alarm for a stuck retry loop.** An order whose
import fails inside OpenELIS is never acknowledged, so it stays `requested` for
ever and its age climbs without limit. The same rule covers "the laboratory is
down", "nobody has collected it" and "it is looping" — which is fine, because
all three need a person.

---

## 5. Three things learned building it, that generalise

These are the reasons the collector is shaped the way it is. Each cost real
time, and each applies to any service in the estate.

### A gauge that has never refreshed must be ABSENT, not zero

Every Prometheus client registers a gauge at `0` the moment you construct it. An
early version of the bridge's refresh loop threw on every pass, so all four
gauges sat at zero and read as *"nothing stuck, no dead letters, catalogue
fresh"* — **the most alarming possible state publishing the most reassuring
possible numbers**, with every alert satisfied by a component that had never
once queried the database.

The bridge now does not **construct** them until a refresh has returned real
values:

```ts
gauges ??= createGauges();
```

So a broken collector produces no series at all, and the alert expression breaks
instead of being quietly satisfied. It also means a `/metrics` scrape in the
first twenty seconds after a restart legitimately shows no `bridge_*` gauges.

### A rule can be `health: ok` and incapable of firing

Prometheus validates that an expression **parses**, not that the metric it names
exists. Rename a gauge and its alerts go silent for ever behind a green rules
page. The **Status → Rules** page showing all seven green tells you nothing about
whether they can fire.

```bash
make monitoring     # 16 checks: collector, gauges, rules, and the fire path
```

That suite asserts every metric named by every alert still resolves to a real
series. It is the only thing that catches a renamed gauge.

### Do not bind-mount single config files

Mounting `alerts.yml` directly served Prometheus a **truncated** copy — the
container kept an inode from an earlier write, so six of the seven rules loaded
and all six reported healthy. A missing alert is the exact failure this
component exists to prevent, and the mount introduced it.

Mount the **directory**. `compose/platform.yml` carries the comment so nobody
undoes it.

---

## 6. Metrics answer "is it wrong now", not "did it all add up"

Alerts cannot see a slow leak. One order a day going missing crosses no
threshold — the oldest-undelivered age keeps being reset as stuck orders are
resolved or swept, so nothing ever ages past fifteen minutes. Nobody notices
until somebody counts.

```bash
make reconcile            # last 7 days
make reconcile DAYS=30
```

That ledger is derived from `order_tracking`, `forwarded_results` and
`dead_letters` at read time — nothing is written to produce it, so it cannot
drift from the data it describes. Read it right to left: **`>1d` is the column
that matters.** An order outstanding for minutes is ordinary traffic; one
outstanding overnight is a patient whose test nobody is running.

The same split decides what to do after a restart. Gauges reset with the process
and tell you nothing about the outage you just had; the ledger spans it. So the
report to run after an incident is `make reconcile`, not a dashboard — and why a
restart costs no orders in the first place is
[durability.md](durability.md).

---

## 7. Adding a rule

1. Add it to [`monitoring/alerts.yml`](../monitoring/alerts.yml), beside the
   others, with the same comment discipline — **say what the alert means and
   what the responder should do**, not just what the expression tests.
2. If it needs a new metric, expose it in `services/bridge/src/config/metrics.ts`
   and make it **lazily constructed** if it is a gauge (§5).
3. Reload without restarting: `--web.enable-lifecycle` is on.
   ```bash
   docker exec his-prometheus wget -qO- --post-data='' http://localhost:9090/-/reload
   ```
4. **Add it to `make monitoring`.** A rule nothing tests is a rule that will go
   silently dead at the next rename.
5. Prove it can fire — drive the condition, do not just admire the green rule.

Thresholds are chosen to be **actionable**, not tight. 15 minutes for an
undelivered order is long enough that ordinary laboratory latency never trips
it; 45 days for a stale catalogue matches how often a laboratory actually
changes its menu. An alert that cries wolf is one people learn to close.

---

## 8. What is deliberately missing

**Alertmanager. Nothing pages anybody.** An alert fires and waits for someone to
run `make alerts` or open the browser. This is the one gap to close before
go-live, and it is left open on purpose: who is on call and how they are reached
is a decision for the hospital, and a sandbox that shipped one arbitrary answer
would teach it as though it were the answer. Point Alertmanager at these rules
and you are done — nothing else has to change.

**No Grafana.** Seven rules and five gauges do not need a dashboard; `/graph`
and `make alerts` cover it. Add one when you have something worth watching over
time.

**No long-term storage.** Two days. Production answers this with remote-write.

**Kong is scraped but nothing alerts on it.** Deliberate — the plumbing is there
so an edge-latency rule can be added without touching compose.

---

## 9. Quick reference

```bash
make alerts          # what is firing right now, and what is merely pending
make monitoring      # 16 checks — can these rules actually fire?
make reconcile       # the daily ledger: taken on vs resulted
make dead-letters    # failures that need a human, newest first
make export-status   # is OpenELIS still pushing results to us?
```

| | |
|---|---|
| Prometheus | http://localhost:9090 |
| Firing alerts | http://localhost:9090/alerts |
| Ad-hoc queries | http://localhost:9090/graph |
| Rule health *(parses ≠ fires)* | http://localhost:9090/rules |
| Scrape targets | http://localhost:9090/targets |
