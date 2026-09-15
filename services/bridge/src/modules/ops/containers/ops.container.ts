import { DeadLetterModel } from '@shared/models/dead-letter.model.js';
import { OpsModel } from '../models/ops.model.js';
import { OpsController } from '../controllers/ops.controller.js';
import { ExportHealthProbe, ExportMonitor, RetentionService } from '../export.monitor.js';
import { IntegrationGauges } from '../integration.gauges.js';

/** Lazily-created singletons, the same shape the other modules use. */
export class OpsContainer {
  private static _model: OpsModel;
  private static _probe: ExportHealthProbe;
  private static _controller: OpsController;
  private static _gauges: IntegrationGauges;
  private static _monitor: ExportMonitor;
  private static _retention: RetentionService;

  static get model(): OpsModel {
    if (!this._model) this._model = new OpsModel();
    return this._model;
  }

  static get probe(): ExportHealthProbe {
    if (!this._probe) this._probe = new ExportHealthProbe(this.model);
    return this._probe;
  }

  static get controller(): OpsController {
    if (!this._controller) {
      this._controller = new OpsController(this.model, new DeadLetterModel(), this.probe);
    }
    return this._controller;
  }

  static get gauges(): IntegrationGauges {
    if (!this._gauges) this._gauges = new IntegrationGauges(this.model);
    return this._gauges;
  }

  static get monitor(): ExportMonitor {
    if (!this._monitor) this._monitor = new ExportMonitor(this.probe);
    return this._monitor;
  }

  static get retention(): RetentionService {
    if (!this._retention) this._retention = new RetentionService(this.model);
    return this._retention;
  }
}

export default OpsContainer;
