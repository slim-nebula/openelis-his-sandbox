import fs from 'node:fs';
import https from 'node:https';
import tls from 'node:tls';
import { X509Certificate } from 'node:crypto';
import type { Express } from 'express';
import { config } from './env.js';
import { logger } from './logger.js';

/**
 * The mutually-authenticated listener OpenELIS talks to.
 *
 * WHAT THIS REPLACES
 * The FHIR hop used to be plain HTTP, guarded only by an allowlist of source
 * addresses. That authenticates a network location, not a node: it produces no
 * cryptographic identity, no audit evidence, and no protection from anything
 * already inside the segment. IHE ATNA requires node authentication to be
 * bidirectional and certificate-based, and prohibits PHI crossing a link that
 * is not — which is exactly the link a laboratory result travels on.
 *
 * WHY OPENELIS NEEDED NO CHANGE
 * It was already willing to prove who it is. HttpClientConfig in the deployed
 * webapp builds its shared HTTP client with loadKeyMaterial from the keystore
 * this repository already points it at, and FhirConfig gives that client to
 * every FHIR client it makes — the order poll and the result push included.
 * Nothing had ever asked it for a certificate. This asks.
 *
 * The peer is pinned to one certificate rather than to a CA. A CA says "signed
 * by someone we trust"; here exactly one machine may ever connect, so "is this
 * that machine" is the question worth asking, and pinning is the direct answer
 * to it. It also means the bridge holds OpenELIS's public certificate and
 * nothing else: it can recognise OpenELIS, and cannot impersonate it.
 *
 * CERTIFICATES ARE READ PER CONNECTION, NOT AT STARTUP
 * The .NET version learned this the hard way: loading both certificates while
 * the host was being built turned an absent file into a crashloop, and a fresh
 * clone of this repository came up with no bridge at all — the process died
 * before it could say why, and the only symptom was a restart counter.
 *
 * Here the mtime of each file is checked on the raw TCP `connection` event,
 * which fires BEFORE the TLS handshake, so a changed certificate takes effect
 * on the very connection that noticed it. It costs one stat() on a path
 * OpenELIS touches every few seconds, and buys two things: a bridge with no
 * certificates still starts, still serves /health and /ops, and says plainly
 * what is missing; and a rotated certificate needs no restart.
 *
 * It stays fail-CLOSED. No server certificate, or no pinned peer, means no
 * handshake completes. Nothing is admitted that could not prove itself.
 */

interface Pinned {
  certificate: X509Certificate;
  stamp: number;
}

let serverStamp = 0;
let peer: Pinned | null = null;
let peerStamp = 0;

/**
 * Newest mtime across the given files, or null if any is absent. Cheap enough
 * to run per connection, and it is what makes a replaced certificate take
 * effect without a restart.
 */
const stampOf = (...paths: string[]): number | null => {
  let newest = 0;
  for (const path of paths) {
    try {
      const written = fs.statSync(path).mtimeMs;
      if (written > newest) newest = written;
    } catch {
      return null;
    }
  }
  return newest;
};

const lastSaid = new Map<string, number>();

/**
 * Once a minute per distinct message. OpenELIS polls this port every few
 * seconds, so an unthrottled "certificate missing" would produce thousands of
 * identical lines an hour and bury whatever else went wrong — including on the
 * shared log topic, where it would be everyone's problem.
 */
const say = (level: 'info' | 'warn' | 'error', key: string, message: string): void => {
  const now = Date.now();
  const last = lastSaid.get(key);
  if (last !== undefined && now - last < 60_000) return;
  lastSaid.set(key, now);
  logger[level](message);
};

/** The pinned peer certificate, reloaded when the file changes. */
const pinnedPeer = (): X509Certificate | null => {
  const stamp = stampOf(config.mtls.peerCertPath);

  if (stamp === null) {
    say(
      'error',
      'mtls-no-peer-cert',
      `${config.mtls.peerCertPath} is missing, so every client certificate will be refused. ` +
        "It is exported from OpenELIS's own truststore — `make certs` with OpenELIS running.",
    );
    peer = null;
    return null;
  }

  if (peer && stamp === peerStamp) return peer.certificate;

  try {
    const certificate = new X509Certificate(fs.readFileSync(config.mtls.peerCertPath));
    peer = { certificate, stamp };
    peerStamp = stamp;
    say(
      'info',
      'mtls-peer-cert',
      `Pinned the FHIR peer to ${certificate.subject.replace(/\n/g, ' ')} (${certificate.fingerprint})`,
    );
    return certificate;
  } catch (error) {
    say('error', 'mtls-bad-peer-cert', `Could not read the pinned peer certificate: ${(error as Error).message}`);
    peer = null;
    return null;
  }
};

/**
 * Rebuilds the listener's certificate when the files on disk change.
 *
 * Returns false when the server certificate is absent, which leaves the
 * listener with no usable context: it still accepts TCP connections, and every
 * handshake fails. That is the strict outcome without the crashloop.
 */
const refreshServerContext = (server: https.Server): boolean => {
  const stamp = stampOf(config.mtls.certPath, config.mtls.keyPath);

  if (stamp === null) {
    say(
      'error',
      'mtls-no-server-cert',
      `BRIDGE_MTLS_ENABLED is true but ${config.mtls.certPath} or ${config.mtls.keyPath} is missing, ` +
        'so no handshake on the FHIR port can complete. Run `make certs`.',
    );
    return false;
  }

  if (stamp === serverStamp) return true;

  try {
    const cert = fs.readFileSync(config.mtls.certPath);
    const key = fs.readFileSync(config.mtls.keyPath);
    const peerCertificate = pinnedPeer();

    server.setSecureContext({
      cert,
      key,
      // The pinned certificate doubles as the trust anchor. OpenELIS's is
      // self-signed, so it validates against itself, and a certificate from any
      // other issuer — including this repository's own CA, which `make negative`
      // deliberately mints one from — fails the chain before the pin is even
      // consulted.
      //
      // When the peer file is missing this is left unset rather than empty:
      // an empty `ca` makes Node fall back to its BUILT-IN root store, which
      // would accept any publicly-signed certificate. The pin below refuses
      // regardless, but a door should not be quietly unlocked on the way to
      // being blocked further in.
      ...(peerCertificate ? { ca: [peerCertificate.toString()] } : {}),
    });

    serverStamp = stamp;
    const loaded = new X509Certificate(cert);
    say(
      'info',
      'mtls-server-cert',
      `Serving the FHIR port as ${loaded.subject.replace(/\n/g, ' ')}, expiring ${loaded.validTo}`,
    );
    return true;
  } catch (error) {
    say('error', 'mtls-bad-server-cert', `Could not load the FHIR port certificate: ${(error as Error).message}`);
    return false;
  }
};

/**
 * The mutually authenticated listener, or null when mutual TLS is off.
 *
 * The SAME Express app is handed to both servers. Nothing in a route needs to
 * know which one a request arrived on, except the FHIR peer guard, which reads
 * req.socket.localPort deliberately.
 */
export const createMtlsServer = (app: Express): https.Server | null => {
  if (!config.mtls.enabled) {
    logger.info('BRIDGE_MTLS_ENABLED is false: /fhir is served on the plaintext port only');
    return null;
  }

  // Created with no certificate material. Everything is supplied by
  // refreshServerContext below, including the first time — so a missing file is
  // a refused handshake rather than a constructor that throws.
  //
  // requestCert asks for a certificate; rejectUnauthorized is deliberately
  // FALSE, and this is the single most important line in the file.
  //
  // THE PIN IS THE CHECK, NOT THE CHAIN. .NET's ClientCertificateValidation
  // REPLACES the platform's chain validation — the .NET service compared
  // thumbprints and returned true, so expiry, issuer and key usage were never
  // consulted. Reproducing that needs chain validation switched off here, with
  // the pin below as the only gate.
  //
  // That is not a shortcut, and it was not discovered by reading. OpenELIS's
  // client certificate EXPIRED on 2026-07-23 and it is still polling the
  // laboratory every few seconds today, accepted on its thumbprint. Leaving
  // rejectUnauthorized true made this listener refuse the real OpenELIS with
  // "no suitable signature algorithm" while correctly refusing the impostors —
  // the rewrite would have passed every negative test and cut the laboratory
  // off at cutover.
  //
  // A pin is a stronger statement than a chain anyway: "this exact
  // certificate", not "something a trusted issuer vouched for and is in date".
  // What it does NOT give is rotation-by-expiry, so an expired peer is called
  // out in the log every time it is accepted, rather than passing silently.
  const server = https.createServer({ requestCert: true, rejectUnauthorized: false }, app);

  // Loaded ONCE, here, before the server can accept anything.
  //
  // This line is not redundant with the 'connection' handler below, and leaving
  // it out cost a debugging session: tls.Server registers its OWN 'connection'
  // listener when it is constructed, so it runs before any listener added
  // afterwards and builds the TLSSocket from whatever context exists at that
  // moment. Refreshing only on 'connection' therefore leaves the FIRST
  // connection — and only the first — with the empty context it was created
  // with, which fails the handshake with "no suitable signature algorithm".
  //
  // In production that is the first poll after every restart failing, and
  // nothing else, which is about as awkward a symptom as this could have.
  refreshServerContext(server);

  // Rotation. The mtime check costs one stat() on a path OpenELIS touches every
  // few seconds, so a replaced certificate is picked up without a restart.
  //
  // Because of the listener ordering above, a rotated certificate takes effect
  // on the connection AFTER the one that noticed it. At one poll every few
  // seconds that is a sub-second lag, and the alternative — an SNICallback —
  // only fires when the client sends SNI, so a peer connecting by IP would
  // silently keep the old context instead.
  server.on('connection', () => void refreshServerContext(server));

  /**
   * The pin itself, checked once the handshake has produced a peer certificate.
   *
   * Compared as raw DER bytes rather than as a fingerprint. A fingerprint is a
   * hash of exactly these bytes, so comparing the bytes is the same question
   * asked without a hash function in the way — and it sidesteps the choice
   * between .NET's SHA-1 thumbprint and something stronger. The SHA-1 form is
   * still what gets logged, because that is what `openssl x509 -fingerprint`
   * and this repository's documentation show.
   */
  server.on('secureConnection', (socket: tls.TLSSocket) => {
    const expected = pinnedPeer();
    const presented = socket.getPeerCertificate();

    if (expected && presented?.raw && presented.raw.equals(expected.raw)) {
      // Accepted on the pin. If the chain ALSO failed — expired, most likely —
      // say so, throttled, so that a certificate nobody has rotated is visible
      // in the log rather than being a fact only this comment knows.
      if (!socket.authorized && socket.authorizationError) {
        say(
          'warn',
          `mtls-pinned-but-unverified:${String(socket.authorizationError)}`,
          `The pinned FHIR peer was accepted but does not pass chain validation ` +
            `(${String(socket.authorizationError)}). The pin is the control, so traffic continues; ` +
            'regenerate the peer certificate to clear this.',
        );
      }
      return;
    }

    const subject = presented?.subject
      ? Object.entries(presented.subject)
          .map(([k, v]) => `${k}=${String(v)}`)
          .join(', ')
      : 'none';

    // Worth a log line either way: an unknown certificate is either a
    // misconfiguration or something that should not be on this network, and
    // both want investigating.
    say(
      'warn',
      `mtls-peer-rejected:${presented?.fingerprint ?? 'none'}`,
      `Refused a client certificate on the FHIR port: subject ${subject}, ` +
        `fingerprint ${presented?.fingerprint ?? 'none'}`,
    );

    // Destroyed before any request is read, so the caller sees no HTTP response
    // at all — which is what `make negative` asserts with a curl status of 000.
    socket.destroy();
  });

  // A handshake that never produced a certificate ends here instead. Throttled
  // by reason: a peer retrying every few seconds must not fill the log.
  server.on('tlsClientError', (error: Error) => {
    say('warn', `mtls-handshake:${error.message}`, `Refused a TLS handshake on the FHIR port: ${error.message}`);
  });

  return server;
};
