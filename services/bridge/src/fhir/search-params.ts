/**
 * Reading FHIR search parameters off a query string.
 *
 * Pure, and separate from the controller, because the failure these prevent is
 * silent: a parameter read wrongly does not error, it returns an empty
 * searchset that is indistinguishable from "nothing is waiting".
 */

/** What Express hands back for one query parameter. */
export type RawQueryValue = string | string[] | undefined | null | unknown;

/**
 * A FHIR token parameter that may carry SEVERAL values.
 *
 * FHIR allows a token parameter to name alternatives, and a client may send
 * them either way:
 *
 *     ?status=requested,received              comma-separated — the FHIR "OR"
 *     ?status=requested&status=received       repeated, which Express gives as an array
 *
 * Both forms must mean the same thing. Before this existed, the comma form was
 * compared verbatim against `content ->> 'status'` as the literal string
 * `"requested,received"` and matched nothing, while the repeated form silently
 * kept only the first value.
 *
 * WHY THAT MATTERED. OpenELIS's own remote poll asks for `requested` AND
 * `received`. A Task it had acknowledged as `received` — an intermediate state,
 * not a verdict — but had not finished importing then fell out of the only set
 * the poll can see. It was not leased, not deliverable and not counted, and the
 * order sat at SENT_TO_LIS for ever with nothing reporting a fault. Dropping a
 * status is not a narrower search; it is an order lost quietly.
 *
 * Returns null for "not specified", which callers read as "do not filter on
 * this" — distinct from an empty set, which would mean "match nothing".
 */
export const tokenSet = (raw: RawQueryValue): string[] | null => {
  const values = (Array.isArray(raw) ? raw : [raw])
    .filter((v): v is string => typeof v === 'string')
    // A trailing or doubled comma is a client's typo, not a request to match
    // the empty string, so blanks are dropped rather than passed to SQL.
    .flatMap((v) => v.split(','))
    .map((v) => v.trim())
    .filter((v) => v.length > 0);

  return values.length > 0 ? values : null;
};

/** A parameter that carries exactly one value; extra values are ignored. */
export const tokenOne = (raw: RawQueryValue): string | null => {
  const value = Array.isArray(raw) ? raw[0] : raw;
  return typeof value === 'string' ? value : null;
};
