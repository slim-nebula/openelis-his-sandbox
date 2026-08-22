import axios, { type AxiosInstance } from 'axios';
import { config } from '@config/env.js';

/**
 * Base for calls to OTHER HIS services.
 *
 * Mirrors the estate's BaseApiClient, including that those calls currently go
 * through the API gateway rather than direct. Nothing in this service uses it
 * yet — it is here so the pattern is present where a developer copying this
 * service will look for it.
 *
 * Two things to know if you extend it:
 *
 * The gateway route is a real trade-off, not an oversight. It buys circuit
 * breaking and per-route metrics from Kong for free; it costs two network hops,
 * makes Kong a dependency of service-to-service traffic, and counts internal
 * calls against Kong's global per-IP rate limit. Moving to direct calls means
 * replacing what Kong was providing — a circuit breaker belongs HERE, in this
 * one file, so every client inherits it the way they inherit the base URL.
 *
 * The timeout is short on purpose. A downstream service that has stopped
 * answering should fail this caller quickly rather than hold its request
 * handlers open until they are all gone.
 */
export abstract class BaseApiClient {
  protected static readonly client: AxiosInstance = axios.create({
    baseURL: process.env.API_GATEWAY_URL || '',
    timeout: 3000,
  });
}

/**
 * Calls to the BRIDGE, which is not an HIS service and does not go through the
 * gateway.
 *
 * The bridge is the single container straddling the boundary to OpenELIS, and
 * the architecture rests on that boundary being narrow. Routing its traffic out
 * to the public edge and back would widen exactly the path everything else is
 * arranged to keep narrow, and would make a gateway outage stop the laboratory
 * as well as the ordering screen.
 *
 * Longer timeout than BaseApiClient: this reads a whole test menu, not a field.
 */
export const bridgeClient: AxiosInstance = axios.create({
  baseURL: config.bridge.internalUrl,
  timeout: 60_000,
});
