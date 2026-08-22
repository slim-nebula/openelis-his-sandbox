import { CatalogueModel } from '../models/catalogue.model.js';
import { CatalogueService } from '../services/catalogue.service.js';
import { CatalogueController } from '../controllers/catalogue.controller.js';

export class CatalogueContainer {
  private static _model: CatalogueModel;
  private static _service: CatalogueService;
  private static _controller: CatalogueController;

  static get catalogueModel(): CatalogueModel {
    if (!this._model) this._model = new CatalogueModel();
    return this._model;
  }

  static get catalogueService(): CatalogueService {
    if (!this._service) this._service = new CatalogueService(this.catalogueModel);
    return this._service;
  }

  static get catalogueController(): CatalogueController {
    if (!this._controller) this._controller = new CatalogueController(this.catalogueService);
    return this._controller;
  }
}

export default CatalogueContainer;
