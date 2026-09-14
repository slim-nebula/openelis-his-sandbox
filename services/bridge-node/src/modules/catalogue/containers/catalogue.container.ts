import { CatalogueModel } from '../models/catalogue.model.js';
import { CatalogueController } from '../controllers/catalogue.controller.js';

/**
 * Lazily-created singletons, the same shape his-api and patient-service use.
 * No DI framework: the graph is small enough that a container of getters is
 * clearer than a framework, and it keeps construction order explicit.
 */
export class CatalogueContainer {
  private static _model: CatalogueModel;
  private static _controller: CatalogueController;

  static get model(): CatalogueModel {
    if (!this._model) this._model = new CatalogueModel();
    return this._model;
  }

  static get controller(): CatalogueController {
    if (!this._controller) this._controller = new CatalogueController(this.model);
    return this._controller;
  }
}

export default CatalogueContainer;
