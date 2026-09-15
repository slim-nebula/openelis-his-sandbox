/**
 * Postgres `date` columns arrive as JS Date in UTC. The API contract is a plain
 * calendar date — a date of birth has no time and no zone, and rendering it as
 * an instant is how a birthday moves by a day for anyone east of Greenwich.
 */
export const toDateOnly = (value: unknown): string | null => {
  if (value === null || value === undefined) return null;
  if (value instanceof Date) return value.toISOString().slice(0, 10);
  return String(value).slice(0, 10);
};

/** `timestamptz` → ISO 8601, or null. */
export const toIso = (value: unknown): string | null => {
  if (value === null || value === undefined) return null;
  if (value instanceof Date) return value.toISOString();
  return new Date(String(value)).toISOString();
};

/**
 * The estate's success envelope.
 *
 * Note this service's CLIENT-facing routes return bare resources rather than
 * this wrapper, because the sandbox frontend, the test suites and the bridge
 * were built against that shape and changing it would be a breaking change to
 * a published contract for cosmetic consistency. Errors DO use the envelope,
 * since those were never part of the contract.
 */
export const ok = <T>(data: T, message = 'OK') => ({ status: true, message, data });
