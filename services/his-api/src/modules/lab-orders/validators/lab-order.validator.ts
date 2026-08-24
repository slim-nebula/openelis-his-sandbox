import { z } from 'zod';
import { DomainError } from '@core/exceptions/http.exceptions.js';

export const createLabOrderSchema = z.object({
  patientId: z.string().uuid('patientId must be a uuid.'),
  testCode: z.string().min(1, 'testCode is required.'),
  facilityCode: z.string().min(1, 'facilityCode is required.'),
  priority: z.string().optional(),
});

export const parseCreateLabOrder = (body: unknown) => {
  // Refused, not ignored.
  //
  // The ordering provider now comes from the token. zod strips unknown keys by
  // default, so simply removing it from the schema would make a caller's value
  // vanish silently — the request would succeed and the order would name
  // somebody else, which is a worse failure than an error. Whoever is still
  // sending this field believes it does something.
  //
  // The clinical stakes are why it is worth an error: the ordering provider is
  // who receives the result, who is telephoned about a critical value, and who
  // is accountable for acting on it.
  if (body !== null && typeof body === 'object' && 'orderingProvider' in body) {
    throw new DomainError(
      'orderingProvider is not accepted: the ordering clinician is taken from your session, ' +
      'not from the request body.',
    );
  }

  const result = createLabOrderSchema.safeParse(body);
  if (!result.success) {
    throw new DomainError(result.error.issues[0]?.message ?? 'Invalid lab order payload.');
  }
  const value = result.data;
  return {
    patientId: value.patientId,
    testCode: value.testCode.trim(),
    facilityCode: value.facilityCode.trim(),
    priority: value.priority?.trim().toLowerCase() || 'routine',
  };
};

export const parseReleasedResult = (payload: unknown) => {
  const schema = z.object({
    orderNumber: z.string().min(1, 'orderNumber and openelisResultRef are required.'),
    openelisResultRef: z.string().min(1, 'orderNumber and openelisResultRef are required.'),
  });
  const result = schema.safeParse(payload);
  if (!result.success) {
    throw new DomainError(result.error.issues[0]?.message ?? 'Invalid result payload.');
  }
};
