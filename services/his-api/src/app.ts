import fs from 'node:fs';
import path from 'node:path';
import express from 'express';
import cors from 'cors';
import swaggerUi from 'swagger-ui-express';
import YAML from 'yaml';
import { config } from '@config/env.js';
import { register, metricsMiddleware } from '@config/metrics.js';
import { correlation } from '@core/middleware/correlation.middleware.js';
import { errorHandler } from '@core/middleware/error.middleware.js';
import { authenticateUser, requireGroup } from '@core/middleware/auth.middleware.js';
import { requireInternalKey } from '@core/middleware/internal.middleware.js';
import patientRoutes from '@modules/patients/routes/patient.routes.js';
import patientInternalRoutes from '@modules/patients/routes/internal.routes.js';
import labOrderRoutes from '@modules/lab-orders/routes/lab-order.routes.js';
import labOrderInternalRoutes from '@modules/lab-orders/routes/internal.routes.js';
import internalResultRoutes from '@modules/lab-orders/routes/internal-results.routes.js';
import visitRoutes from '@modules/lab-orders/routes/visit.routes.js';
import {
  catalogueRouter,
  catalogueAdminRouter,
} from '@modules/catalogue/routes/catalogue.routes.js';

const startedAt = Date.now();
const app = express();

app.use(express.json());
app.use(
  cors({
    origin: '*',
    methods: ['GET', 'POST', 'PUT', 'OPTIONS'],
    allowedHeaders: ['Accept', 'Content-Type', 'X-Correlation-ID', 'Authorization'],
    exposedHeaders: ['X-Correlation-ID'],
  }),
);

app.use(correlation);
app.use(metricsMiddleware);

// Served at the estate's path, from a file rather than jsdoc annotations, so
// the contract can be reviewed in a diff instead of assembled at runtime.
const swaggerDocument = YAML.parse(
  fs.readFileSync(path.join(process.cwd(), 'swagger.yaml'), 'utf8'),
);
app.use(
  '/api/his/api-docs',
  swaggerUi.serve,
  swaggerUi.setup(swaggerDocument, { swaggerOptions: { docExpansion: 'list' } }),
);
app.get('/api/his/api-docs.json', (_req, res) => res.json(swaggerDocument));

// --- Platform surface -------------------------------------------------------
// What the estate reads: Consul's check and Prometheus's scrape. Both answer
// without a credential — a health check that can fail authentication reports an
// outage that is not happening.

app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

app.get('/health', async (_req, res) => {
  // Reaching the database is the honest test. A service answering "healthy"
  // while unable to read its own state stays in Kong's rotation, and every
  // request routed to it fails.
  const { pool } = await import('@config/db.js');
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

app.get('/', (_req, res) => {
  res.json({ message: 'his-api service' });
});

// --- Client-facing API ------------------------------------------------------
// Routed through the reverse proxy and Kong, and behind the estate's user
// token: everything below reads or writes patient data, so the service needs to
// know *which clinician* is asking, not merely that somebody is.
const asUser = [authenticateUser, requireGroup(config.auth.labGroup)];

app.use('/patients', asUser, patientRoutes);
app.use('/lab-orders', asUser, labOrderRoutes);
app.use('/visits', asUser, visitRoutes);
app.use('/test-catalogue', asUser, catalogueRouter);

// The catalogue refresh keeps its shared operator token rather than a user
// token. It is run by a script and by the deployment, neither of which is a
// person with an IAM account.
app.use('/admin/catalogue', catalogueAdminRouter);

// --- Internal API -----------------------------------------------------------
// Bridge-facing only, and deliberately NOT routed by Kong: the bridge reaches
// this service directly over the sandbox network, so integration traffic never
// transits the public edge. The key is what stops anything *else* on that
// network reading the same endpoints.
app.use('/internal/patients', requireInternalKey, patientInternalRoutes);
app.use('/internal/lab-orders', requireInternalKey, labOrderInternalRoutes);
app.use('/internal/lab-results', requireInternalKey, internalResultRoutes);

// Last: Express dispatches to the error handler only from here.
app.use(errorHandler);

export default app;
