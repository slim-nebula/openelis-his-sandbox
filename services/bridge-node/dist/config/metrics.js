import promClient, { Counter, Gauge, Histogram, Registry, Summary } from 'prom-client';
import { config } from './env.js';
/**
 * The estate's metric contract, plus the five the integration adds.
 *
 * Its own Registry rather than the global default, so nothing a dependency
 * registers leaks onto this service's /metrics.
 */
export const register = new Registry();
register.setDefaultLabels({ service: config.serviceName });
// --- The estate's four ------------------------------------------------------
// Same names, labels and buckets as his-api, so one dashboard and one alert
// rule cover every service.
const httpRequestCount = new Counter({
    name: 'http_requests_total',
    help: 'HTTP requests by method, route and status',
    labelNames: ['method', 'route', 'status'],
    registers: [register],
});
const httpRequestDuration = new Histogram({
    name: 'http_request_duration_seconds',
    help: 'HTTP request duration in seconds',
    labelNames: ['method', 'route', 'status'],
    buckets: [0.005, 0.01, 0.05, 0.1, 0.3, 0.5, 1],
    registers: [register],
});
const inFlightRequests = new Gauge({
    name: 'in_flight_requests',
    help: 'Requests currently being served',
    labelNames: ['method', 'route'],
    registers: [register],
});
const httpLatencySummary = new Summary({
    name: 'http_request_latency_summary_seconds',
    help: 'HTTP request latency percentiles',
    labelNames: ['method', 'route'],
    percentiles: [0.5, 0.9, 0.99],
    registers: [register],
});
// --- How each FHIR request arrived ------------------------------------------
/**
 * Worth a metric rather than a log line: "is the laboratory link actually
 * mutually authenticated, right now" is a question worth alerting on, and a
 * configuration file cannot answer it — a setting can be true while nothing is
 * using the port.
 *
 * transport="plaintext" above zero, on a deployment that believes it has mutual
 * TLS, means something is still coming in the other way.
 */
export const fhirRequests = new Counter({
    name: 'bridge_fhir_requests_total',
    help: 'FHIR requests by how the connection was authenticated',
    labelNames: ['transport'],
    registers: [register],
});
promClient.collectDefaultMetrics({ register });
let gauges = null;
const createGauges = () => {
    const made = {
        oldestRequested: new Gauge({
            name: 'bridge_oldest_requested_task_age_seconds',
            help: 'Age of the oldest Task still awaiting collection by the laboratory. 0 when none.',
            registers: [register],
        }),
        deadLetters: new Gauge({
            name: 'bridge_dead_letters_total',
            help: 'Rows in bridge.dead_letters — failures that need a human.',
            registers: [register],
        }),
        catalogueAge: new Gauge({
            name: 'bridge_catalogue_age_seconds',
            help: 'Time since the test menu was last synced from OpenELIS.',
            registers: [register],
        }),
        lastPollAge: new Gauge({
            name: 'bridge_last_poll_age_seconds',
            help: 'Time since OpenELIS last polled for orders. -1 until the first poll of this process.',
            registers: [register],
        }),
    };
    return made;
};
/** Called only after a refresh has actually read the database. */
export const publishIntegrationGauges = (values) => {
    gauges ??= createGauges();
    gauges.oldestRequested.set(values.oldestRequestedTaskAgeSeconds);
    gauges.deadLetters.set(values.deadLetters);
    gauges.catalogueAge.set(values.catalogueAgeSeconds);
    gauges.lastPollAge.set(values.lastPollAgeSeconds);
};
export const integrationGaugesPublished = () => gauges !== null;
// --- Request instrumentation ------------------------------------------------
export const metricsMiddleware = (req, res, next) => {
    const endHistogram = httpRequestDuration.startTimer();
    const endSummary = httpLatencySummary.startTimer();
    // A constant label on the way in, so the matching dec() always finds the same
    // series. The real route is not known until the router has matched.
    inFlightRequests.inc({ method: req.method, route: 'pending' });
    res.on('finish', () => {
        // The route TEMPLATE, never req.path: /fhir/Task/{id} as a label would mint
        // one time series per order and eventually per patient.
        const route = `${req.baseUrl || ''}${req.route?.path ?? ''}` || 'unmatched';
        const status = res.statusCode.toString();
        httpRequestCount.labels(req.method, route, status).inc();
        endHistogram({ method: req.method, route, status });
        endSummary({ method: req.method, route });
        inFlightRequests.dec({ method: req.method, route: 'pending' });
    });
    next();
};
