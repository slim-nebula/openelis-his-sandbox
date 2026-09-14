import { CatalogueModel } from '../models/catalogue.model.js';
import { CatalogueController } from '../controllers/catalogue.controller.js';
import { CatalogueSync } from '../catalogue.sync.js';

/**
 * Lazily-created singletons, the same shape his-api and patient-service use.
 * No DI framework: the graph is small enough that a container of getters is
 * clearer than a framework, and it keeps construction order explicit.
 */
export class CatalogueContainer {
  private static _model: CatalogueModel;
  private static _sync: CatalogueSync;
  private static _controller: CatalogueController;

  static get model(): CatalogueModel {
    if (!this._model) this._model = new CatalogueModel();
    return this._model;
  }

  static get sync(): CatalogueSync {
    if (!this._sync) this._sync = new CatalogueSync(this.model);
    return this._sync;
  }

  static get controller(): CatalogueController {
    if (!this._controller) this._controller = new CatalogueController(this.model, this.sync);
    return this._controller;
  }
}

export default CatalogueContainer;
