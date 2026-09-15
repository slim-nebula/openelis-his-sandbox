export interface IPatient {
  patientId: string;
  mrn: string;
  firstName: string;
  lastName: string;
  sex: string;
  dateOfBirth: string | null;
  phone: string | null;
  nationalId: string | null;
  createdAt: string | null;
}

export interface ICreatePatientInput {
  mrn?: string | undefined;
  firstName: string;
  lastName: string;
  sex: string;
  dateOfBirth: string;
  phone?: string | undefined;
  nationalId?: string | undefined;
}
