import { z } from 'zod';
import { DomainError } from '@core/exceptions/http.exceptions.js';

/**
 * Sex is normalised rather than rejected. The field feeds a FHIR Patient sent
 * to OpenELIS, which expects male/female/unknown — so an unrecognised value
 * becomes 'U' instead of failing a registration. Refusing to register a patient
 * over a demographic field would be the wrong trade in a hospital.
 */
const normaliseSex = (value: string): string => {
  switch (value.trim().toUpperCase()) {
    case 'M':
    case 'MALE':
      return 'M';
    case 'F':
    case 'FEMALE':
      return 'F';
    default:
      return 'U';
  }
};

const blank = (value: string | undefined): string | undefined => {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
};

export const createPatientSchema = z.object({
  mrn: z.string().optional(),
  firstName: z.string().min(1, 'firstName and lastName are required.'),
  lastName: z.string().min(1, 'firstName and lastName are required.'),
  sex: z.string().default('U'),
  dateOfBirth: z.string().min(1, 'dateOfBirth is required.'),
  phone: z.string().optional(),
  nationalId: z.string().optional(),
});

export const parseCreatePatient = (body: unknown) => {
  const result = createPatientSchema.safeParse(body);
  if (!result.success) {
    throw new DomainError(result.error.issues[0]?.message ?? 'Invalid patient payload.');
  }

  const value = result.data;
  return {
    mrn: blank(value.mrn),
    firstName: value.firstName.trim(),
    lastName: value.lastName.trim(),
    sex: normaliseSex(value.sex),
    dateOfBirth: value.dateOfBirth,
    phone: blank(value.phone),
    nationalId: blank(value.nationalId),
  };
};
