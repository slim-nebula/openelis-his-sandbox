export interface IPatient {
  patientId: string;
  externalPatientId: string;
  firstName: string;
  lastName: string;
  sex: string;
  dateOfBirth: string | null;
  phone: string | null;
  nationalId: string | null;
  createdAt: string | null;
}

export interface ICreatePatientInput {
  externalPatientId?: string | undefined;
  firstName: string;
  lastName: string;
  sex: string;
  dateOfBirth: string;
  phone?: string | undefined;
  nationalId?: string | undefined;
}
