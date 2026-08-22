import { z } from 'zod';
import { DomainError } from '@core/exceptions/http.exceptions.js';

export const createLabOrderSchema = z.object({
  patientId: z.string().uuid('patientId must be a uuid.'),
  testCode: z.string().min(1, 'testCode is required.'),
  orderingProvider: z.string().min(1, 'orderingProvider is required.'),
  facilityCode: z.string().min(1, 'facilityCode is required.'),
  priority: z.string().optional(),
});

export const parseCreateLabOrder = (body: unknown) => {
  const result = createLabOrderSchema.safeParse(body);
  if (!result.success) {
    throw new DomainError(result.error.issues[0]?.message ?? 'Invalid lab order payload.');
  }
  const value = result.data;
  return {
    patientId: value.patientId,
    testCode: value.testCode.trim(),
    orderingProvider: value.orderingProvider.trim(),
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
