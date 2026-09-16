import { BillingMapModel } from '../models/billing-map.model.js';
import { BillingService } from '../services/billing.service.js';
import { BillingController } from '../controllers/billing.controller.js';

export class BillingContainer {
  private static _model: BillingMapModel;
  private static _service: BillingService;
  private static _controller: BillingController;

  static get billingMapModel(): BillingMapModel {
    if (!this._model) this._model = new BillingMapModel();
    return this._model;
  }

  static get billingService(): BillingService {
    if (!this._service) this._service = new BillingService(this.billingMapModel);
    return this._service;
  }

  static get billingController(): BillingController {
    if (!this._controller) this._controller = new BillingController(this.billingService);
    return this._controller;
  }
}

export default BillingContainer;
