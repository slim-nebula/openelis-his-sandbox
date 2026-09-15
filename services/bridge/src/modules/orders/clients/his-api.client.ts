import axios, { type AxiosInstance } from 'axios';
import { config } from '@config/env.js';
import { logger } from '@config/logger.js';
import type { IHisOrder } from '../types/order.types.js';

/**
 * Reads an order's full context back from the HIS.
 *
 * The event on the topic carries only ids — deliberately, because an event is a
 * notification and not a record. Everything that reaches the laboratory is
 * fetched here, from the system that owns it, at the moment it is needed. That
 * is what stops a stale event publishing a patient's old name or a test that
 * has since been cancelled.
 */
export class HisApiClient {
  private readonly http: AxiosInstance;

  constructor() {
    this.http = axios.create({
      baseURL: config.hisApiBaseUrl,
      timeout: 15_000,
      // The estate's service-to-service credential, on every call to
      // /internal/*. Set once here rather than at each call site, so a request
      // added later cannot be the one that forgets it.
      headers: config.internalApiKey ? { 'x-internal-api-key': config.internalApiKey } : {},
    });
  }

  /**
   * Fetches an order, retrying with exponential backoff.
   *
   * The retry exists for one specific situation: the HIS service and the bridge
   * start together, and the bridge can consume an event before the HIS is
   * answering. Giving up on the first refusal would dead-letter a perfectly
   * good order because of startup ordering.
   */
  async fetchOrder(orderId: string, correlationId: string): Promise<IHisOrder> {
    let last: Error | null = null;

    for (let attempt = 1; attempt <= config.maxRetries; attempt++) {
      try {
        const response = await this.http.get<IHisOrder>(`/internal/lab-orders/${orderId}`, {
          headers: { 'X-Correlation-ID': correlationId },
        });
        if (!response.data) throw new Error('Empty order payload');
        return response.data;
      } catch (error) {
        last = error as Error;
        if (attempt >= config.maxRetries) break;

        const delaySeconds = config.retryBaseDelaySeconds * Math.pow(2, attempt - 1);
        logger.warn(
          `Fetch of order ${orderId} failed (attempt ${attempt}): ${last.message}; ` +
            `retrying in ${delaySeconds}s`,
        );
        await new Promise((resolve) => setTimeout(resolve, delaySeconds * 1000));
      }
    }

    throw last ?? new Error(`Could not fetch order ${orderId}`);
  }
}
