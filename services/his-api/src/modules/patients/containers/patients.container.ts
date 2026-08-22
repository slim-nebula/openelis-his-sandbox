import { PatientModel } from '../models/patient.model.js';
import { PatientService } from '../services/patient.service.js';
import { PatientController } from '../controllers/patient.controller.js';
import { LabOrdersContainer } from '@modules/lab-orders/containers/lab-orders.container.js';

/**
 * Centralised dependency management for patient components — singletons,
 * created on first use.
 */
export class PatientsContainer {
  private static _patientModel: PatientModel;
  private static _patientService: PatientService;
  private static _patientController: PatientController;

  static get patientModel(): PatientModel {
    if (!this._patientModel) this._patientModel = new PatientModel();
    return this._patientModel;
  }

  static get patientService(): PatientService {
    if (!this._patientService) this._patientService = new PatientService(this.patientModel);
    return this._patientService;
  }

  static get patientController(): PatientController {
    if (!this._patientController) {
      // The patient controller serves /patients/{id}/lab-orders and /results,
      // which are lab-order reads hanging off a patient route. It borrows that
      // module's service rather than reaching into its tables.
      this._patientController = new PatientController(
        this.patientService,
        LabOrdersContainer.labOrderService,
      );
    }
    return this._patientController;
  }
}

export default PatientsContainer;
