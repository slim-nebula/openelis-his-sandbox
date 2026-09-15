import type { Request, Response } from 'express';
import { parseCreatePatient } from '../validators/patient.validator.js';
import type { PatientService } from '../services/patient.service.js';
import type { LabOrderService } from '@modules/lab-orders/services/lab-order.service.js';

export class PatientController {
  constructor(
    private readonly patients: PatientService,
    private readonly orders: LabOrderService,
  ) {}

  create = async (req: Request, res: Response): Promise<void> => {
    const patient = await this.patients.create(parseCreatePatient(req.body));
    res.status(201).location(`/patients/${patient.patientId}`).json(patient);
  };

  search = async (req: Request, res: Response): Promise<void> => {
    const limit = req.query.limit ? Number(req.query.limit) : undefined;
    const term = typeof req.query.q === 'string' ? req.query.q : undefined;
    res.json(await this.patients.search(term, limit));
  };

  getById = async (req: Request, res: Response): Promise<void> => {
    res.json(await this.patients.getById(req.params.id as string));
  };

  listOrders = async (req: Request, res: Response): Promise<void> => {
    res.json(await this.orders.listForPatient(req.params.id as string));
  };

  listResults = async (req: Request, res: Response): Promise<void> => {
    res.json(await this.orders.resultsForPatient(req.params.id as string));
  };
}
