import { NotFoundError } from '@core/exceptions/http.exceptions.js';
import { logger } from '@config/logger.js';
import type { PatientModel } from '../models/patient.model.js';
import type { IPatient, ICreatePatientInput } from '../types/patient.types.js';

export class PatientService {
  constructor(private readonly patients: PatientModel) {}

  async create(input: ICreatePatientInput): Promise<IPatient> {
    const patient = await this.patients.create(input);
    logger.info(`Patient ${patient.externalPatientId} registered (${patient.patientId})`);
    return patient;
  }

  async getById(patientId: string): Promise<IPatient> {
    const patient = await this.patients.findById(patientId);
    if (!patient) throw new NotFoundError(`Unknown patient '${patientId}'.`);
    return patient;
  }

  /**
   * Clamped rather than validated. A caller asking for 10,000 rows gets 200 and
   * a working screen; rejecting them would just move the failure to the client
   * for no protection the clamp does not already give.
   */
  async search(term: string | undefined, limit: number | undefined): Promise<IPatient[]> {
    const bounded = Math.min(Math.max(limit ?? 25, 1), 200);
    return this.patients.search(term, bounded);
  }
}
