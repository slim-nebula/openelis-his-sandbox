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
| 2 | FHIR store and the `/fhir` surface, delivery lease | not started |
| 3 | order consumer, mapper, refusal matrix | not started |
| 4 | result correlator, progress tracker | not started |
| 5 | catalogue sync, OpenELIS REST client | not started |
| 6 | ops surface: dead letters, ledger, retention, export monitor, gauges | not started |
| 7 | mutual TLS listener and peer pinning | not started |
| 8 | delete the C#, repoint the docs, rename to `services/bridge` | not started |

The plan, including the contract this must not break, is in the session plan
file; the acceptance criterion is the existing 355 checks passing unchanged.

## Running it outside Docker

Faster than rebuilding the image for every change. Needs only the database:

```bash
npm install && npm run build
BRIDGE_DB_CONNECTION="Host=localhost;Port=55432;Database=bridge_sandbox;Username=bridge_app;Password=bridge_app_pw" \
SERVICE_PORT=18099 node dist/server.js
```

`BRIDGE_DB_CONNECTION` is accepted in both the Npgsql shape compose builds and
as a plain `postgres://` URL — see `databaseConnection()` in `src/config/env.ts`.
