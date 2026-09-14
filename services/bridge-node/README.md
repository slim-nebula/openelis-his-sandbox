# bridge-service (Node)

The integration service, being rewritten from .NET into the estate's own stack:
Node 20, Express 5, TypeScript, ESM — the same shape as `services/his-api` and
as `patient-service` in the real HIS.

**This is a work in progress.** `services/Bridge` (C#) is still the one compose
builds and still the one serving the laboratory. Nothing here is wired in until
the suites pass against it.

## Why

The sandbox exists so the user's developers can read it and copy it. A C#
service is the one part of it they cannot maintain, and the integration logic —
which is the valuable part — is language-independent.

## Progress

| Phase | Scope | State |
|---|---|---|
| 0 | RFC 4122 v5 ids reproduce the .NET ones exactly | done |
| 1 | config, db, logger, metrics, Consul, `/health`, `/`, `/catalogue` | done |
| 2a | mutual TLS listener, peer pinning, `/fhir` guard, `/fhir/metadata` | done |
| 2b | FHIR store and the rest of the `/fhir` surface, delivery lease | next |
| 3 | order consumer, mapper, refusal matrix | not started |
| 4 | result correlator, progress tracker | not started |
| 5 | catalogue sync, OpenELIS REST client | not started |
| 6 | ops surface: dead letters, ledger, retention, export monitor, gauges | not started |
| 7 | shutdown drain and hot-reload polish | not started |
| 8 | delete the C#, repoint the docs, rename to `services/bridge` | not started |

Mutual TLS moved ahead of the FHIR store because OpenELIS reaches this service
at `https://bridge.openelis.org:8443/fhir` and nowhere else, so nothing it does
could be proven end to end until the listener existed — and finding a TLS
blocker after 150 lines is cheaper than after 1,500.

The acceptance criterion is the existing 355 checks passing unchanged.

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
