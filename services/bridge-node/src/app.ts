import express from 'express';
import { config } from '@config/env.js';
import { pool } from '@config/db.js';
import { register, metricsMiddleware } from '@config/metrics.js';
import { correlation } from '@core/middleware/correlation.js';
import { errorHandler } from '@core/middleware/error.js';
import { requireOpsAccess } from '@core/middleware/ops-access.js';
import { fhirPeerGuard } from '@core/middleware/fhir-peer-guard.js';
import { problemResponse } from '@core/middleware/error.js';
import { catalogueRouter, catalogueAdminRouter } from '@modules/catalogue/routes/catalogue.routes.js';
import { fhirRouter } from '@modules/fhir-api/routes/fhir.routes.js';

const app = express();
const startedAt = Date.now();

// --- Pipeline ---------------------------------------------------------------
// Order matters. The FHIR surface parses its own body (it is application/
// fhir+json, not application/json, and must tolerate what OpenELIS sends), so
// express.json() is mounted per-router rather than globally.

app.use(correlation);
app.use(metricsMiddleware);

// --- Platform surface -------------------------------------------------------
// What the estate reads: Consul's check, Prometheus's scrape. Both must answer
// without a credential — a health check that can fail authentication reports an
// outage that is not happening, and takes the service out of Kong's rotation
// for a reason that has nothing to do with its health.

app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

/**
 * Reaching the database is the honest test. A service that answers "healthy"
 * while unable to read its own state gets left in Kong's rotation, and every
 * request routed to it fails.
 */
app.get('/health', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
  } catch (error) {
    res.status(503).json({
      service: config.serviceName,
      status: 'unhealthy',
      detail: (error as Error).message,
    });
    return;
  }

  res.json({
    service: config.serviceName,
    instance: process.env.HOSTNAME || 'localhost',
    status: 'healthy',
    timestamp: new Date().toISOString(),
    uptime: Number(((Date.now() - startedAt) / 1000).toFixed(3)),
    version: config.serviceVersion,
  });
});

/** What this service is, for a human who has just found it in the Consul UI. */
app.get('/', (_req, res) => {
  res.json({
    message: 'bridge service',
    fhirEndpoint: '/fhir',
    labOwner: config.labOwnerReference,
  });
});

// --- Public surface ---------------------------------------------------------
// Read-only and service-to-service: the cached menu his-api mirrors.

app.use('/catalogue', catalogueRouter);

// --- Operational and administrative surface ---------------------------------
// Everything past this point either changes something or describes the health
// of the integration in detail. Both are worth a bearer token: the first
// because an unauthenticated caller could empty the doctor's test menu, the
// second because "which orders are outstanding and which failed" is a
// description of real patients' care.

app.use('/catalogue', requireOpsAccess, express.json(), catalogueAdminRouter);

// --- The FHIR R4 endpoint OpenELIS integrates with --------------------------
// Guarded at the prefix, not per route: the surface is several handlers plus a
// bare POST /fhir for the result bundle, and a prefix cannot be forgotten when
// one more is added.
//
// The body parser is the FHIR router's own. OpenELIS sends
// application/fhir+json, which express.json() does not accept by default, and
// the limit is raised well above Express's 100 KB default — a released panel
// with its observations, or a Bundle carrying several, exceeds it, and Kestrel
// allowed ~30 MB.
app.use(
  '/fhir',
  fhirPeerGuard,
  express.json({
    type: ['application/fhir+json', 'application/json'],
    limit: '10mb',
    // The raw text is kept alongside the parsed object because the parsed one
    // cannot be trusted to round-trip: JavaScript has a single number type, so
    // a result of 1.10 re-serialises as 1.1 and silently loses the precision
    // the laboratory reported. Writes use this; the parsed body is only read
    // for routing decisions. See getText() in the FHIR model.
    verify: (req, _res, buf) => {
      (req as express.Request).rawBody = buf.toString('utf8');
    },
  }),
  fhirRouter,
);

/**
 * Anything unmatched, in the shape the rest of this service answers in.
 *
 * Express's default is an HTML page, which is the one content type no caller
 * here can parse: the estate reads problem+json and OpenELIS reads FHIR. A
 * request under /fhir gets an OperationOutcome for that reason.
 */
app.use((req, res) => {
  if (req.path.startsWith('/fhir')) {
    res.status(404).type('application/fhir+json').send(
      '{"resourceType":"OperationOutcome","issue":[{"severity":"error","code":"not-found","diagnostics":"Unknown FHIR endpoint."}]}',
    );
    return;
  }
  problemResponse(res, 404, `No endpoint matches ${req.method} ${req.path}.`);
});

// Express dispatches to the error handler only from here.
app.use(errorHandler);

export default app;
