import { CatalogueModel } from '../models/catalogue.model.js';
import { CatalogueController } from '../controllers/catalogue.controller.js';
/**
 * Lazily-created singletons, the same shape his-api and patient-service use.
 * No DI framework: the graph is small enough that a container of getters is
 * clearer than a framework, and it keeps construction order explicit.
 */
export class CatalogueContainer {
    static _model;
    static _controller;
    static get model() {
        if (!this._model)
            this._model = new CatalogueModel();
        return this._model;
    }
    static get controller() {
        if (!this._controller)
            this._controller = new CatalogueController(this.model);
        return this._controller;
    }
}
export default CatalogueContainer;
