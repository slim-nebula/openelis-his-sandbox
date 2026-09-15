import { CatalogueModel } from '@modules/catalogue/models/catalogue.model.js';
import { DeadLetterModel } from '@shared/models/dead-letter.model.js';
import { EventClaimModel } from '@shared/models/event-claim.model.js';
import { HisApiClient } from '../clients/his-api.client.js';
import { OrderTrackingModel } from '../models/order-tracking.model.js';
import { OrderConsumer } from '../order.consumer.js';

/**
 * Lazily-created singletons, the same shape the other modules use.
 *
 * The consumer is where several modules' models meet — orders, the catalogue,
 * and the two shared store concerns. That joining happens HERE and in the
 * consumer, never between models, which is what keeps the module seams real.
 */
export class OrdersContainer {
  private static _consumer: OrderConsumer;

  static get consumer(): OrderConsumer {
    if (!this._consumer) {
      this._consumer = new OrderConsumer(
        new HisApiClient(),
        new OrderTrackingModel(),
        new CatalogueModel(),
        new EventClaimModel(),
        new DeadLetterModel(),
      );
    }
    return this._consumer;
  }
}

export default OrdersContainer;
