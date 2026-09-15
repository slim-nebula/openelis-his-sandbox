import { randomUUID } from 'node:crypto';
import { query, queryOne, type Row } from '@config/db.js';
import { toDateOnly, toIso } from '@shared/utils/serialization.utils.js';
import type { IPatient, ICreatePatientInput } from '../types/patient.types.js';

const COLUMNS = `patient_id, mrn, first_name, last_name, sex,
                 date_of_birth, phone, national_id, created_at`;

const toPatient = (row: Row): IPatient => ({
  patientId: String(row.patient_id),
  mrn: String(row.mrn),
  firstName: String(row.first_name),
  lastName: String(row.last_name),
  sex: String(row.sex),
  dateOfBirth: toDateOnly(row.date_of_birth),
  phone: row.phone === null ? null : String(row.phone),
  nationalId: row.national_id === null ? null : String(row.national_id),
  createdAt: toIso(row.created_at),
});

export class PatientModel {
  /**
   * MRNs come from a sequence, not count(*) + 1.
   *
   * Counting rows reissues a number as soon as any patient is deleted, and two
   * concurrent registrations read the same count and compute the same MRN. The
   * unique constraint caught that, so the symptom was a registration that
   * errored rather than a duplicate MRN — but a constraint is a last line of
   * defence, not an allocation strategy.
   */
  private async nextMrn(): Promise<string> {
    const row = await queryOne<Row>(`SELECT nextval('his.mrn_seq') AS n`);
    return `MRN-${String(row?.n ?? 0).padStart(6, '0')}`;
  }

  async create(input: ICreatePatientInput): Promise<IPatient> {
    const mrn = input.mrn ?? (await this.nextMrn());

    const row = await queryOne<Row>(
      `INSERT INTO his.patients
           (patient_id, mrn, first_name, last_name, sex,
            date_of_birth, phone, national_id)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       RETURNING ${COLUMNS}`,
      [
        randomUUID(),
        mrn,
        input.firstName,
        input.lastName,
        input.sex,
        input.dateOfBirth,
        input.phone ?? null,
        input.nationalId ?? null,
      ],
    );
    return toPatient(row!);
  }

  async findById(patientId: string): Promise<IPatient | null> {
    const row = await queryOne<Row>(
      `SELECT ${COLUMNS} FROM his.patients WHERE patient_id = $1`,
      [patientId],
    );
    return row ? toPatient(row) : null;
  }

  async exists(patientId: string): Promise<boolean> {
    const row = await queryOne<Row>(
      'SELECT exists(SELECT 1 FROM his.patients WHERE patient_id = $1) AS present',
      [patientId],
    );
    return row?.present === true;
  }

  async search(term: string | undefined, limit: number): Promise<IPatient[]> {
    const pattern = `%${(term ?? '').trim().toLowerCase()}%`;
    const rows = await query<Row>(
      `SELECT ${COLUMNS}
         FROM his.patients
        WHERE $1 = '%%'
           OR lower(last_name)  LIKE $1
           OR lower(first_name) LIKE $1
           OR lower(mrn) LIKE $1
           OR lower(coalesce(national_id, '')) LIKE $1
        ORDER BY created_at DESC
        LIMIT $2`,
      [pattern, limit],
    );
    return rows.map(toPatient);
  }
}
