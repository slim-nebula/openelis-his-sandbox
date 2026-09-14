/**
 * ISO-8601, or null. Postgres hands back a Date for timestamptz and a string
 * for anything already text, and the wire format is always the string.
 */
export const toIso = (value) => {
    if (value === null || value === undefined)
        return null;
    if (value instanceof Date)
        return value.toISOString();
    const parsed = new Date(String(value));
    return Number.isNaN(parsed.getTime()) ? String(value) : parsed.toISOString();
};
/**
 * A number from whatever node-postgres handed back.
 *
 * Not decoration: `count(*)` arrives as a STRING because it is bigint, and
 * `extract(epoch …)` arrives as a string because it is numeric. Feeding either
 * straight into a Prometheus gauge publishes NaN. The SQL in this service casts
 * as well — belt and braces, because the failure is silent in both directions.
 */
export const toNumber = (value, fallback = 0) => {
    if (value === null || value === undefined)
        return fallback;
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
};
/** `yyyy-MM-dd` from a Date or a date-ish string, for the ledger's day buckets. */
export const toDateOnly = (value) => {
    const iso = toIso(value);
    return iso ? (iso.split('T')[0] ?? null) : null;
};
