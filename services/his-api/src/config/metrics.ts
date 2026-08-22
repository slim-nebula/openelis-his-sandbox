import promClient, { Counter, Gauge, Histogram, Registry, Summary } from 'prom-client';
import type { NextFunction, Request, Response } from 'express';
import { config } from './env.js';

/**
 * The same four series the other services expose, so one dashboard and one set
 * of alert rules cover the estate.
 */
export const register = new Registry();
register.setDefaultLabels({ service: config.serviceName });

const httpRequestCount = new Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status'],
});

const httpRequestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.005, 0.01, 0.05, 0.1, 0.3, 0.5, 1],
});

const inFlightRequests = new Gauge({
  name: 'in_flight_requests',
  help: 'Number of HTTP requests currently in flight',
  labelNames: ['method', 'route'],
});

const httpLatencySummary = new Summary({
  name: 'http_request_latency_summary_seconds',
  help: 'Summary of HTTP request latency in seconds',
  labelNames: ['method', 'route'],
  percentiles: [0.5, 0.9, 0.99],
});

/**
 * One series beyond the estate's four, because degraded authentication is
 * otherwise invisible: the requests still succeed, so no error rate moves, and
 * the only trace is a log line at the start of the outage.
 *
 * `result="degraded"` above zero means revocation is not being enforced —
 * logouts are not taking effect. It is the series to alert on.
 */
export const authChecks = new Counter({
  name: 'auth_revocation_checks_total',
  help: 'Token revocation checks by outcome',
  labelNames: ['result'],
});

register.registerMetric(authChecks);
register.registerMetric(httpRequestCount);
register.registerMetric(httpRequestDuration);
register.registerMetric(inFlightRequests);
register.registerMetric(httpLatencySummary);
promClient.collectDefaultMetrics({ register });

export const metricsMiddleware = (req: Request, res: Response, next: NextFunction): void => {
  // req.route is not populated until routing has run, so the label is resolved
  // in the finish handler. Falling back to req.path would put every patient id
  // in a separate time series and blow up cardinality.
  const endHistogram = httpRequestDuration.startTimer();
  const endSummary = httpLatencySummary.startTimer();
  const method = req.method;

  const routeOf = (): string => {
    const base = (req.baseUrl || '') + (req.route?.path ?? '');
    return base || 'unmatched';
  };

  inFlightRequests.inc({ method, route: 'pending' });

  res.on('finish', () => {
    const route = routeOf();
    const status = res.statusCode.toString();
    httpRequestCount.labels(method, route, status).inc();
    endHistogram({ method, route, status });
    endSummary({ method, route });
    inFlightRequests.dec({ method, route: 'pending' });
  });

  next();
};
