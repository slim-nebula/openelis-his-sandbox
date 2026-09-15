import { LabOrderModel } from '../models/lab-order.model.js';
import { LabOrderService } from '../services/lab-order.service.js';
import { LabOrderController } from '../controllers/lab-order.controller.js';

export class LabOrdersContainer {
  private static _labOrderModel: LabOrderModel;
  private static _labOrderService: LabOrderService;
  private static _labOrderController: LabOrderController;

  static get labOrderModel(): LabOrderModel {
    if (!this._labOrderModel) this._labOrderModel = new LabOrderModel();
    return this._labOrderModel;
  }

  static get labOrderService(): LabOrderService {
    if (!this._labOrderService) this._labOrderService = new LabOrderService(this.labOrderModel);
    return this._labOrderService;
  }

  static get labOrderController(): LabOrderController {
    if (!this._labOrderController) {
      this._labOrderController = new LabOrderController(this.labOrderService);
    }
    return this._labOrderController;
  }
}

export default LabOrdersContainer;
