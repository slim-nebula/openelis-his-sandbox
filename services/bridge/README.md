# bridge-service

The integration service: Kafka consumer, FHIR R4 server, result correlator and
operational surface. Node 20, Express 5, TypeScript, ESM — the same shape as
`services/his-api` and as `patient-service` in the real HIS.

Rewritten from .NET in eight gated phases and cut over once the full sweep
passed **355 checks, 0 failures**. The C# service it replaced is in git history
up to commit `ef68420`.

## Why it was rewritten

The sandbox exists so the client's developers can read it and copy it. A C#
service was the one part of it they could not maintain, and the integration
logic — which is the valuable part — is language-independent.

## Layout

```
src/
  app.ts            the Express pipeline, and what is guarded
  server.ts         two listeners, the workers, ordered shutdown
  config/           env · db · kafka · logger · metrics · consul · redis · mtls
  core/             exceptions, and the middleware every surface shares
  fhir/             an R4 subset, deterministic ids, serialisation
  modules/
    orders/         consumer, mapper, the refusal matrix
    results/        correlator, progress tracker, flattening
    fhir-api/       the /fhir surface and the delivery lease
    catalogue/      discovery, the OpenELIS REST client, the cached menu
    ops/            /ops, the four gauges, retention, export health
  shared/           models and helpers no single module owns
```

## How it was proven

Each phase ended by running the suites that pin it, against the real sandbox,
and reverting to the .NET build if they were not green — because a partly
ported service must not serve a sandbox others may demo.

Beyond the suites, three things were checked against what the .NET service had
actually written rather than against expectations:

* **deterministic ids** reproduce RFC 4122 v5 against Python's `uuid5`, the
  published python.org vector, and a live row (`task|137539b5-…` →
  `07e60d38-f066-5d30-8c6a-9d9acd56b930`);
* **the mapper** was replayed over 15 real orders — 654 fields across 89
  resources, one difference, and that one a clinician whose name changed in the
  HIS after publication;
* **the flattener** was replayed over every result the .NET bridge had
  delivered — 25 reports and 18 panel components, all matching.

## Deliberate divergences from the .NET service

Each of these was a decision, not an accident. They are listed so phase 8 can
put them in the repository's own documentation rather than leaving them to be
discovered.

| What | .NET | Here | Why |
|---|---|---|---|
| Kafka log level | real level per line | same | his-api ships everything as `info`; copying that would have made `level="warn"` queries match nothing |
| Metric default labels | none | none | `fhir_transport_count` in `scripts/lib.sh` greps for the exact label set, and Prometheus already adds `job`/`component` |
| Request metric labels | `code`/`controller`/`action`/`endpoint` | `method`/`route`/`status` | matches his-api, so one dashboard covers the estate — **a dashboard pinned to the old labels will go blank** |
| Histogram buckets | powers of two | the estate's `0.005…1` | same reason |
| `problem+json` `type` | a link into RFC 9110 | `about:blank` | RFC 7807 §4.2: there is no problem registry to point at |
| Unmatched path under a guarded prefix | 404 | 401 | the guard runs before routing; not revealing which paths exist is the better answer |
| Unmatched path elsewhere | empty 404 | `problem+json` 404 | Express's default is an HTML page, which no caller here can parse |

## Decimal precision, and why reads and writes go through text

JavaScript has one number type. Postgres stores JSON numbers as `numeric` and
keeps `1.10` as `1.10`; a `JSON.parse`/`JSON.stringify` round trip returns `1.1`.

For a laboratory result that trailing zero is not decoration — it states the
precision of the measurement. The .NET service never had the problem: it
selected `content::text` and parsed into a type with real decimals, and a probe
against the running container confirms it stores `1.10` unchanged. A first cut
of this module selected `content` and re-serialised the parsed object, which
silently reported a different number than the analyser produced.

So, on the paths that carry results:

* reads (`getText`, `getReceivedText`) select `content::text` and the text is
  written to the response verbatim;
* writes take the request's **raw body** — captured by a `verify` hook on the
  FHIR body parser — and the id is applied with `jsonb_set` inside Postgres;
* a pushed transaction bundle is split **in SQL** with `jsonb_array_elements`,
  so entries never become JavaScript values. Ids are chosen in TypeScript and
  zipped by position with `WITH ORDINALITY`.

The searches are the deliberate exception: they must embed rows inside a Bundle,
but every one of them reads `fhir_resources`, which holds only what the bridge
publishes — orders, carrying no measured value. **The rule to keep: anything
reading `received_resources` goes through the text path.**

The one place a body is re-serialised is the echo after storing a resource whose
caller supplied no id, because the response has to carry the id the bridge
assigned. The stored row keeps full precision either way.

## Mutual TLS, and one thing worth knowing

The peer is pinned to one certificate, compared as raw DER bytes. Chain
validation is deliberately **off** (`rejectUnauthorized: false`), because .NET's
`ClientCertificateValidation` replaced the platform's chain check with a
thumbprint comparison, and reproducing the behaviour requires the same.

This is not academic. **OpenELIS's client certificate expired on 2026-07-23**
and it is still polling the laboratory, accepted on its thumbprint alone. With
chain validation left on, this listener refused the real OpenELIS while
correctly refusing every impostor — it passed all three negative checks and
would have cut the laboratory off at cutover. An expired-but-pinned peer is now
logged (throttled) every time it is accepted, rather than passing in silence.

## Running it outside Docker

Faster than rebuilding the image for every change. Needs only the database:

```bash
npm install && npm run build
BRIDGE_DB_CONNECTION="Host=localhost;Port=55432;Database=bridge_sandbox;Username=bridge_app;Password=bridge_app_pw" \
SERVICE_PORT=18099 node dist/server.js
```

`BRIDGE_DB_CONNECTION` is accepted in both the Npgsql shape compose builds and
as a plain `postgres://` URL — see `databaseConnection()` in `src/config/env.ts`.

To exercise the mutually authenticated port as well, add the certificate paths
and use `--resolve` so the server certificate's `bridge.openelis.org` SAN is
verified honestly rather than skipped with `-k`:

```bash
BRIDGE_MTLS_ENABLED=true BRIDGE_MTLS_PORT=18443 \
BRIDGE_MTLS_CERT=../../certs/bridge.crt BRIDGE_MTLS_KEY=../../certs/bridge.key \
BRIDGE_MTLS_PEER_CERT=../../certs/openelis-client.crt \
… node dist/server.js

curl --resolve bridge.openelis.org:18443:127.0.0.1 --cacert ../../certs/ca.crt \
     --cert <openelis cert> --key <openelis key> \
     https://bridge.openelis.org:18443/fhir/metadata
```

OpenELIS's private key is in its own keystore (`/etc/openelis-global/keystore`,
alias `1`, password from `SSL_KEYSTORE_PASSWORD`); export it to a scratch
directory if you need the positive case, and delete it afterwards.
