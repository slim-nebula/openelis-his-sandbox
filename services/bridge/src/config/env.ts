import dotenv from 'dotenv';

dotenv.config();

/**
 * Every setting the bridge reads, in one place.
 *
 * The variable NAMES are a contract, not an implementation detail: they are set
 * in compose/apps.yml, asserted by `make negative` (the retention windows are
 * compared against the running service's own answer), and shared with the
 * OpenELIS configuration that this service must agree with. Renaming one here
 * silently breaks a deployment that looks correct.
 *
 * As in his-api, nothing falls back to a real address or credential. A default
 * is either a compose service name that resolves only inside the sandbox
 * network, or an empty string that makes the feature refuse rather than guess.
 */
const required = (key: string): string => {
  const value = process.env[key];
  if (!value) throw new Error(`${key} is required.`);
  return value;
};

const env = (key: string, fallback: string): string => process.env[key] || fallback;

const num = (key: string, fallback: string): number => Number(env(key, fallback));

/**
 * Redis's address, from whichever of the three shapes the estate uses.
 *
 * Same helper as his-api's, and for the same reason: `REDIS_URL=redis:6379`
 * passed into ioredis's `host` field is resolved as a *hostname*, fails, and
 * the service runs permanently in degraded mode with nothing announcing it.
 * The bridge's own .env sets REDIS_URL in exactly that shape.
 */
const redisTarget = (): { host: string; port: number } => {
  const explicitHost = process.env.REDIS_HOST;
  const explicitPort = Number(process.env.REDIS_PORT || '6379');
  if (explicitHost) return { host: explicitHost, port: explicitPort };

  const raw = env('REDIS_URL', '').replace(/^rediss?:\/\//, '');
  if (!raw) return { host: '', port: explicitPort };

  const [host, port] = raw.split(':');
  return { host: host || '', port: Number(port) || explicitPort };
};

/**
 * The database connection, from either shape BRIDGE_DB_CONNECTION may hold.
 *
 * The variable predates this service being written in Node: compose builds it
 * as an **Npgsql** string — `Host=…;Port=…;Database=…;Username=…;Password=…` —
 * which node-postgres cannot parse at all. It does not fail loudly either; it
 * treats the whole thing as a host name and the service simply never connects.
 *
 * Both shapes are accepted rather than renaming the variable, because the name
 * is set in compose, in every deployment's notes, and in a running estate. A
 * semicolon-and-equals string is parsed into discrete fields; anything else is
 * handed to pg as a URL. Parsing into fields also sidesteps URL-encoding a
 * generated password, which is a real trap in the other direction.
 */
export interface DatabaseConnection {
  connectionString?: string;
  host?: string;
  port?: number;
  database?: string;
  user?: string;
  password?: string;
}

/**
 * Exported, and taking the raw string rather than reading the environment, so
 * that it can be tested as the pure function it is. `config` below supplies
 * `required('BRIDGE_DB_CONNECTION')`.
 */
export const parseDatabaseConnection = (raw: string): DatabaseConnection => {
  if (!raw.includes('=')) return { connectionString: raw };

  const parts = new Map<string, string>();
  for (const pair of raw.split(';')) {
    const index = pair.indexOf('=');
    if (index <= 0) continue;
    parts.set(pair.slice(0, index).trim().toLowerCase(), pair.slice(index + 1).trim());
  }

  const port = parts.get('port');
  return {
    host: parts.get('host') ?? 'localhost',
    port: port ? Number(port) : 5432,
    database: parts.get('database') ?? '',
    user: parts.get('username') ?? parts.get('user id') ?? '',
    password: parts.get('password') ?? '',
  };
};

export const config = {
  serviceName: env('SERVICE_NAME', 'bridge-service'),
  serviceVersion: env('SERVICE_VERSION', '1.0.0'),
  port: num('SERVICE_PORT', '8080'),

  database: parseDatabaseConnection(required('BRIDGE_DB_CONNECTION')),

  hisApiBaseUrl: env('HIS_API_INTERNAL_URL', 'http://his-api:8080'),

  kafka: {
    brokers: env('KAFKA_BOOTSTRAP', 'kafka:9092').split(','),
    /**
     * Deliberately NOT an environment variable, matching the .NET service it
     * replaces. `make smoke` asserts a consumer group containing "bridge" is
     * registered with the broker, and a per-deployment group name would turn
     * that into a test of the deployment rather than of the service.
     */
    consumerGroup: 'bridge',
    topics: {
      orderCreated: env('TOPIC_ORDER_CREATED', 'lab.order.created'),
      orderSent: env('TOPIC_ORDER_SENT', 'lab.order.sent'),
      orderFailed: env('TOPIC_ORDER_FAILED', 'lab.order.failed'),
      orderProgress: env('TOPIC_ORDER_PROGRESS', 'lab.order.progress'),
      resultReleased: env('TOPIC_RESULT_RELEASED', 'lab.result.released'),
      resultFailed: env('TOPIC_RESULT_FAILED', 'lab.result.failed'),
      logs: env('TOPIC_LOGS', 'logs'),
    },
  },

  consul: {
    host: env('CONSUL_HOST', ''),
    port: num('CONSUL_PORT', '8500'),
    advertisedIp: process.env.SERVICE_IP || undefined,
  },

  /**
   * Stamped on Task.owner, and the string OpenELIS searches for — it must equal
   * org.openelisglobal.remote.source.identifier exactly.
   *
   * The RESOURCE TYPE is part of the contract, not decoration. It must be
   * Organization: LabOrderSearchProvider attributes the order to the owner
   * whenever the reference contains "Practitioner", which hides the real
   * ordering clinician behind the routing identity.
   *
   * Changing this strands orders already published under the old value — they
   * keep the owner they were written with and no poll will ask for them again.
   * Drain before switching, or republish.
   */
  labOwnerReference: env('OE_REMOTE_SOURCE_IDENTIFIER', 'Organization/openelis-sandbox-lab'),

  /**
   * What the receiving laboratory is called. A laboratory is normally a
   * department INSIDE a hospital, so this is the hospital's own name. The
   * authoritative copy lives in OpenELIS's `organization` table; this is ours,
   * and the two are meant to agree.
   */
  labOwnerName: env('OE_LAB_NAME', 'Laboratory'),

  maxRetries: num('BRIDGE_MAX_RETRIES', '5'),
  retryBaseDelaySeconds: num('BRIDGE_RETRY_BASE_DELAY_SECONDS', '2'),
  correlationRetryMinutes: num('BRIDGE_RESULT_CORRELATION_RETRY_MINUTES', '15'),

  /**
   * Largest number of resources one search may return. Without a cap, the order
   * poll serialises every Task the bridge has ever published into one response,
   * and the cost of asking "anything new?" grows with the age of the deployment.
   */
  maxSearchResults: num('BRIDGE_MAX_SEARCH_RESULTS', '200'),

  /**
   * How long a Task is withheld from the order poll after being handed over.
   *
   * It must comfortably exceed one import, or the lease expires mid-import and
   * re-offers the Task to the very next poll — reintroducing the collision it
   * exists to prevent. A measured import took about five seconds.
   */
  taskLeaseSeconds: num('BRIDGE_TASK_LEASE_SECONDS', '90'),

  access: {
    /** Shared operator token. Empty AND an empty jwtSecret makes /ops answer 503. */
    adminToken: env('BRIDGE_ADMIN_TOKEN', ''),
    /** The estate's signing secret, so a signed-in person can read /ops. */
    jwtSecret: env('JWT_SECRET', ''),
    /** IAM group a user token must carry. Empty allows any authenticated user. */
    opsGroup: env('BRIDGE_OPS_GROUP', ''),
    /** Hostnames permitted to call /fhir on the plaintext port. Empty disables the check. */
    fhirAllowedPeers: env('BRIDGE_FHIR_ALLOWED_PEERS', '')
      .split(',')
      .map((peer) => peer.trim())
      .filter((peer) => peer.length > 0),
  },

  redis: redisTarget(),

  /** Presented to his-api on /internal/*, in the estate's service-to-service header. */
  internalApiKey: env('INTERNAL_API_KEY', ''),

  retention: {
    receivedDays: num('RETENTION_RECEIVED_DAYS', '30'),
    eventsDays: num('RETENTION_EVENTS_DAYS', '14'),
    exportChecksDays: num('RETENTION_EXPORT_CHECKS_DAYS', '30'),
    deadLettersDays: num('RETENTION_DEAD_LETTERS_DAYS', '180'),
    /**
     * Delivery leases, and the only window here that is bounded by SAFETY
     * rather than by usefulness. A lease row is the attempt counter for an
     * order; pruning one whose Task is still `requested` would forget that the
     * laboratory has already been given it, so the sweep below only ever
     * touches Tasks that have left that state.
     */
    leasesDays: num('RETENTION_LEASES_DAYS', '90'),
    /** 0 disables the timer. A laboratory under audit hold cannot be swept by a default. */
    sweepHours: num('RETENTION_SWEEP_HOURS', '24'),
  },

  openElis: {
    baseUrl: env('OE_REST_BASE_URL', ''),
    user: env('OE_SERVICE_USER', ''),
    password: env('OE_SERVICE_PASSWORD', ''),
    timeoutSeconds: num('OE_REST_TIMEOUT_SECONDS', '120'),
    /**
     * Trust any certificate when talking to OpenELIS. True in the sandbox, which
     * serves a self-signed certificate; it must be false anywhere real, which is
     * why it is configuration rather than an unconditional bypass.
     */
    acceptAnyCertificate: env('OE_REST_ACCEPT_ANY_CERT', 'true') === 'true',
    /**
     * The largest share of the menu a single sync may remove before it is
     * refused. A laboratory withdrawing a third of its tests at once is
     * possible; a partial read that looks like one is far likelier.
     */
    maxShrink: Number(env('CATALOGUE_MAX_SHRINK', '0.30')),
    exportCheckMinutes: num('EXPORT_CHECK_MINUTES', '5'),
    /** Missed push cycles tolerated before the channel counts as stale. */
    exportStaleCycles: num('EXPORT_STALE_CYCLES', '5'),
    /** Host OpenELIS names in its subscription, used to find our own entry. */
    publicFhirHost: env('BRIDGE_PUBLIC_FHIR_HOST', 'bridge'),
  },

  mtls: {
    enabled: env('BRIDGE_MTLS_ENABLED', 'false') === 'true',
    port: num('BRIDGE_MTLS_PORT', '8443'),
    certPath: env('BRIDGE_MTLS_CERT', '/certs/bridge.crt'),
    keyPath: env('BRIDGE_MTLS_KEY', '/certs/bridge.key'),
    peerCertPath: env('BRIDGE_MTLS_PEER_CERT', '/certs/openelis-client.crt'),
  },
} as const;

/** Catalogue discovery is optional; without credentials those endpoints refuse rather than crash. */
export const catalogueDiscoveryConfigured = (): boolean =>
  config.openElis.baseUrl.length > 0 &&
  config.openElis.user.length > 0 &&
  config.openElis.password.length > 0;
