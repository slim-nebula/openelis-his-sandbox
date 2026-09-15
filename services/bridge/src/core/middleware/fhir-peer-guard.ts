import dns from 'node:dns/promises';
import { isIPv4 } from 'node:net';
import type { NextFunction, Request, Response } from 'express';
import { config } from '@config/env.js';
import { logger } from '@config/logger.js';
import { fhirRequests } from '@config/metrics.js';

/**
 * Who may reach /fhir.
 *
 * SUPERSEDED, AND KEPT ON PURPOSE
 * With BRIDGE_MTLS_ENABLED this is no longer the control on the live path: the
 * mutually authenticated port proves identity with a certificate and does not
 * consult the allowlist at all. What it still governs is the plaintext port,
 * which mutual TLS restricts to loopback anyway — so it is a second lock on a
 * door that is already shut, and the fallback if mutual TLS is turned off to
 * bisect a problem.
 *
 * WHY THIS WAS EVER THE ANSWER, AND WHY IT IS NOT A TOKEN
 * OpenELIS 3.2.1.11 has no way to authenticate to a remote FHIR source. Two
 * independent facts in the shipped webapp establish it:
 *
 *   * FhirConfig declares property placeholders for fhirstore.username /
 *     .password and crserver.username / .password, but for the remote source
 *     only remote.source.uri. There is no key to put a credential in.
 *   * The one BasicAuthInterceptor it registers is guarded by a comparison of
 *     the target URL against getLocalFhirStorePath(). The bridge is not the
 *     local store, so the header is never attached.
 *
 * The result push arrives through a FHIR Subscription, whose channel supports
 * headers in the R4 model — but RegisterFhirHooksTask exposes no property to
 * populate them either.
 *
 * So a bearer token on /fhir would not secure the integration, it would end it.
 * That is why the answer is a certificate at the transport layer rather than a
 * credential in a header. An address allowlist authenticates a network
 * location, not a node, and IHE ATNA requires the latter.
 */

// Byte-for-byte what the .NET service returned. `make negative` greps the
// second one for "requires a mutually authenticated TLS connection".
const FORBIDDEN_OUTCOME =
  '{"resourceType":"OperationOutcome","issue":[{"severity":"error","code":"forbidden","diagnostics":"Caller is not a permitted FHIR peer."}]}';

const PLAINTEXT_REFUSED_OUTCOME =
  '{"resourceType":"OperationOutcome","issue":[{"severity":"error","code":"security","diagnostics":"This endpoint requires a mutually authenticated TLS connection."}]}';

const CACHE_FOR_MS = 60_000;

let allowed = new Set<string>();
let resolvedAt = 0;

/**
 * Node reports an IPv4 peer as ::ffff:172.20.0.5 on a dual-stack socket, which
 * never equals the IPv4 address DNS returned.
 */
const normalise = (address: string): string => {
  const mapped = address.startsWith('::ffff:') ? address.slice('::ffff:'.length) : address;
  return isIPv4(mapped) ? mapped : mapped.toLowerCase();
};

const isLoopback = (address: string): boolean =>
  address === '::1' || address === '127.0.0.1' || address.startsWith('127.');

const resolvePeers = async (): Promise<void> => {
  const resolved = new Set<string>();

  for (const peer of config.access.fhirAllowedPeers) {
    try {
      for (const entry of await dns.lookup(peer, { all: true })) {
        resolved.add(normalise(entry.address));
      }
    } catch (error) {
      // One unresolvable peer must not empty the allowlist and lock out the
      // others: OpenELIS's FHIR store and its webapp do not restart together.
      logger.warn(`Could not resolve FHIR peer ${peer}: ${(error as Error).message}`);
    }
  }

  if (resolved.size > 0) {
    allowed = resolved;
    resolvedAt = Date.now();
  } else {
    logger.error(`No FHIR peer resolved; keeping the previous allowlist of ${allowed.size}`);
  }
};

const matches = async (remote: string, forceRefresh: boolean): Promise<boolean> => {
  if (forceRefresh || Date.now() - resolvedAt > CACHE_FOR_MS) await resolvePeers();
  return allowed.has(remote);
};

const isAllowedPeer = async (remote: string): Promise<boolean> => {
  if (config.access.fhirAllowedPeers.length === 0) return true;

  // A request from inside this container is already past every boundary this
  // guard defends; anything able to make one could edit the allowlist instead.
  // The test suites reach /fhir this way.
  if (isLoopback(remote)) return true;

  if (await matches(remote, false)) return true;

  // A container that was recreated has a new address, and the old one is cached
  // for up to a minute. Re-resolve once before refusing, so a restart of
  // OpenELIS does not silently stop orders for that minute.
  return matches(remote, true);
};

const outcome = (res: Response, body: string): void => {
  res.status(403).type('application/fhir+json').send(body);
};

/**
 * Mounted on the /fhir prefix rather than per-route: the FHIR surface is served
 * by several routers plus a bare POST /fhir for the result bundle, and a prefix
 * cannot be forgotten when one more is added.
 */
export const fhirPeerGuard = async (req: Request, res: Response, next: NextFunction): Promise<void> => {
  const remote = normalise(req.socket.remoteAddress ?? '');
  const loopback = isLoopback(remote);
  const onMtlsPort = config.mtls.enabled && req.socket.localPort === config.mtls.port;

  // Counted here, BEFORE any decision, so a refused plaintext attempt is
  // counted too. Those are the interesting ones: they are how a caller still
  // using the old address announces itself.
  fhirRequests.labels(onMtlsPort ? 'mtls' : loopback ? 'loopback' : 'plaintext').inc();

  // With mutual TLS on, the plaintext port stops being a way in. Without this
  // the whole exercise is decorative: a caller that did not want to present a
  // certificate could simply use the other port and be back to an address
  // check.
  if (config.mtls.enabled && !onMtlsPort && !loopback) {
    logger.warn(
      `Refused ${req.method} ${req.originalUrl} from ${remote || 'unknown'}: ` +
        `/fhir requires the mutually authenticated port ${config.mtls.port}`,
    );
    outcome(res, PLAINTEXT_REFUSED_OUTCOME);
    return;
  }

  // On the mutually authenticated port the certificate IS the control, and the
  // address allowlist is not consulted.
  //
  // This was not the first design. Both checks were kept at first, on the
  // reasoning that two controls are better than one. Turning it on showed why
  // that is wrong here: the handshake succeeded, the certificate was accepted,
  // and the allowlist then refused the request anyway — because Docker's DNS
  // answers `openelis-webapp` with its address on ONE of the networks the two
  // containers share, and the connection arrives from a different one.
  //
  // A weaker check that can veto a stronger one is not defence in depth. It is
  // a second thing that can fail, guarding a door that is already locked
  // better. The certificate proves identity cryptographically; an address does
  // not, and cannot.
  if (onMtlsPort) {
    next();
    return;
  }

  if (await isAllowedPeer(remote)) {
    next();
    return;
  }

  logger.warn(`Refused ${req.method} ${req.originalUrl} from ${remote || 'unknown'}: not an allowed FHIR peer`);
  outcome(res, FORBIDDEN_OUTCOME);
};

/** Said once at startup, so an empty allowlist is a stated choice and not a surprise. */
export const announceFhirPeerPolicy = (): void => {
  if (config.access.fhirAllowedPeers.length === 0) {
    logger.warn(
      'BRIDGE_FHIR_ALLOWED_PEERS is empty: the FHIR endpoint accepts a result or an order ' +
        'poll from anything that can reach this container',
    );
  } else {
    logger.info(`FHIR endpoint restricted to ${config.access.fhirAllowedPeers.join(', ')}`);
  }
};
