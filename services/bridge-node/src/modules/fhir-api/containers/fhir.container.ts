import { FhirModel } from '../models/fhir.model.js';
import { FhirController } from '../controllers/fhir.controller.js';
import { OrderTrackingModel } from '@modules/orders/models/order-tracking.model.js';

/**
 * Lazily-created singletons, the same shape his-api and patient-service use.
 *
 * The controller holds two models — the FHIR store and order tracking — because
 * the update route has to tell OpenELIS's verdict on our order apart from
 * OpenELIS pushing us a resource, and that needs both. The models themselves
 * import nothing of each other: joining concerns is the controller's job, which
 * is what keeps the seams between modules real.
 */
export class FhirContainer {
  private static _store: FhirModel;
  private static _tracking: OrderTrackingModel;
  private static _controller: FhirController;

  static get store(): FhirModel {
    if (!this._store) this._store = new FhirModel();
    return this._store;
  }

  static get tracking(): OrderTrackingModel {
    if (!this._tracking) this._tracking = new OrderTrackingModel();
    return this._tracking;
  }

  static get controller(): FhirController {
    if (!this._controller) this._controller = new FhirController(this.store, this.tracking);
    return this._controller;
  }
}

export default FhirContainer;
