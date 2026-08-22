# Platform integration

How the sandbox's services present themselves to the HIS platform, and why each
hook is shaped the way it is.

The sandbox is a reference implementation for the real HIS. That means matching
its **infrastructure contracts**, not inventing better ones: the same health
document, the same Consul registration, the same metric names, the same log
envelope. A service that is correct but shaped differently teaches the wrong
lesson to whoever copies it, and is invisible to the tooling that has to run it.

Both .NET services now carry these. `services/*/Platform.cs` holds them, and the
two copies are deliberately identical — the services share no project, because
each Dockerfile builds from its own directory, so it is duplicated rather than
referenced. **When one changes, change both.**

---

## The four hooks

| Hook | Path / target | Matches |
|---|---|---|
| Health | `GET /health` | `{service, instance, status, timestamp, uptime}` |
| Metrics | `GET /metrics` | `http_requests_total`, `http_request_duration_seconds` |
| Discovery | Consul `agent/service/register` | tags `hospital`, `microservice`, `load-balanced`, `version-x`; 10s/3s check; 30s critical deregistration |
| Logs | Kafka `logs` topic | `{service, level, message, timestamp}` |

`/healthz` is gone. It was a Kubernetes-ism that nothing in this estate uses,
and having two health paths is how one of them ends up stale.

---

## Four decisions worth knowing

### 1. Health checks the database, not just the process

A service that answers `healthy` while unable to read its own state stays in
Kong's rotation, and every request routed to it fails. `/health` opens a
connection and runs `SELECT 1`; on failure it returns **503** with the reason,
which is what makes Consul mark it critical and take it out of rotation.

### 2. A registry outage does not stop the laboratory

The Node services call `process.exit(1)` if Consul registration fails. These log
the error and carry on.

The reasoning is specific to what the bridge does: it moves patient results, and
it can do that perfectly well unregistered — OpenELIS polls it by hostname and
Kafka does not consult a registry. Refusing to start would convert a discovery
problem into a clinical one.

This is a genuine divergence from the Node services, and a deliberate one.

### 3. Log shipping is filtered, bounded, and never blocks

The `logs` topic is **shared with every service in the estate**, so the question
is not "is this worth logging" but "is this worth putting on everyone's bus".

ASP.NET emits four Information lines per request — starting, executing,
executed, finished. With a Consul check every 10s and a Docker healthcheck
alongside it, an idle bridge produced **~2,800 messages in five minutes**, none
of them about a patient. Framework categories now ship only at Warning and
above, which took the same idle window to **21**. Framework *warnings* still
ship: "connection reset", "request rejected" are exactly what is wanted
centrally.

Two further properties, neither optional:

- **It never blocks a request.** Lines go onto a bounded channel drained by a
  background pump. When the channel is full they are **dropped**, because a
  logging subsystem that consumes memory until the process dies has turned an
  observability problem into an outage.
- **It never logs.** The obvious implementation publishes through the bridge's
  `EventPublisher`, which logs every publish — which publishes, which logs. It
  holds its own producer and reports failures to `stderr`, once per distinct
  reason. Failing in complete silence is how a log pipeline ends up dead for
  months without anyone noticing.

### 4. The advertised address comes from the routing table

This one caused a real failure and is worth reading before copying the Node
implementation anywhere else.

`ConsulRegistration` in the Node services takes **eth0**. That is correct for
them: each sits on a single Docker network, so it has one address and eth0 is
it.

The bridge sits on **three** networks — that multi-homing *is* the architectural
boundary between the HIS estate and OpenELIS. Taking eth0 registered it at its
`oe-data-net` address while Consul watches `oe-sandbox-net`. The service
appeared in the catalogue and every health check failed:

```
bridge-service   172.24.0.4:8080   bridge-service-health=critical
```

A service in the catalogue that Consul cannot reach is **worse** than one that
never registered, because Kong will route to it.

The question is not "what is my address" but "what is my address *from Consul's
side*", and only the routing table can answer it. Connecting a UDP socket sends
no packets — it asks the kernel which local address it would use to reach that
destination:

```csharp
using var probe = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
probe.Connect(options.ConsulHost, options.ConsulPort);
var local = ((IPEndPoint)probe.LocalEndPoint!).Address;
```

**This matters for the real HIS too.** The moment any service there joins a
second network, its eth0 registration becomes a coin flip.

---

## Kong routes through Consul

Kong used to address `http://his-api:8080` — a Docker hostname — while the real
platform addresses `<name>.service.consul`.

That difference produced a live fault. Both services were recreated, Docker
reassigned their addresses, and Kong served a request for `/api/health`
**from the bridge**, because it had cached the address that now belonged to the
other container:

```
$ curl localhost:8090/api/health
{"service":"bridge-service", ...}      # expected his-api-service
```

Kong now resolves through Consul, as the HIS platform does:

```yaml
# gateway/kong/kong.yml
- name: his-patient-laborder-service
  protocol: http
  host: his-api-service.service.consul
  port: 8080
```

**Consul needs a fixed address for this**, because Kong's `dns_resolver` takes
an address rather than a name — the same constraint the real HIS solves with its
`CONSUL_HOST` default of `10.10.0.12`. So the sandbox network has an explicit
subnet (`SANDBOX_SUBNET`) and Consul has a pinned address in it (`CONSUL_IP`).
Nothing else is pinned; the whole point of registering is that everything else
can move.

`A` records only (`KONG_DNS_ORDER: A,CNAME`). Consul answers SRV for these names
too, but its SRV targets point at synthetic `.addr.<dc>.consul` names needing a
second resolution step, and the port is already declared on the service.

### What this buys beyond fixing the stale cache

Consul only answers with instances whose **health check is passing**. So a
service that cannot reach its database — which is what `/health` actually tests
— drops out of DNS and stops receiving traffic, rather than being routed to and
failing every request.

Measured:

| | |
|---|---|
| `docker stop his-api` | Consul withdrew it in **~5 s** |
| `GET /api/health` | **503**, rather than routing to a dead container |
| `docker start his-api` | back in rotation automatically, Kong untouched |

503 is the right answer here. Routing anyway and returning whatever a stopped
container produces would be worse; returning 200 would be a lie.

**Withdrawal is eventual, not instantaneous.** Consul notices within its 10s
check interval, and Kong may serve a cached record for up to `dns_stale_ttl`
after that. Steady state is 503 — confirmed from Kong directly and through the
edge — but during the transition Kong has been observed returning 500 or 502
while it still holds an address for a container that is gone.

So the test asserts Kong stops returning *success*, not that it returns one
particular code at one particular instant. The first version demanded 503
immediately and caught Kong mid-cache, which was a race in the test rather than
a fault in the system.

Shortening that window means a shorter check interval and more health traffic.
10s matches what the Node services register, and matching them matters more here
than shaving three seconds.

`make up` still restarts Kong, which is now belt-and-braces rather than the
mitigation it used to be.

---

## What is tested

`make smoke`, in the *Platform integration* section:

- both services are registered in Consul
- **Consul can reach the address each advertised** — the regression test for the
  multi-homing bug above, since registration alone proves nothing
- both carry the estate's tags
- both expose Prometheus request histograms
- application logs arrive on the shared topic in the estate's envelope
- **framework chatter does not** — asserted causally rather than historically:
  16 health requests must add ≤ 8 messages, not the ~64 they produced before the
  filter. Sampling the tail of the topic would have tested what the service did
  last week rather than what it does now.
