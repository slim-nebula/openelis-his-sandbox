import type { FhirResource } from '@fhir/types.js';
import type { IObservation } from './models/received.model.js';

/** The flat fields the HIS stores, collapsed out of one FHIR Observation. */
export interface IFlatResult {
  value: string | null;
  unit: string | null;
  referenceRange: string | null;
  interpretation: string | null;
  interpretationCode: string | null;
}

const asArray = (value: unknown): Record<string, unknown>[] =>
  Array.isArray(value) ? (value as Record<string, unknown>[]) : [];

const str = (value: unknown): string | null =>
  typeof value === 'string' && value.trim().length > 0 ? value : null;

/** Every `coding` entry across a list of CodeableConcepts. */
const codingsOf = (concepts: unknown): Record<string, unknown>[] =>
  asArray(concepts).flatMap((concept) => asArray(concept.coding));

/**
 * The analyte's own code. LOINC where the laboratory supplied one, because that
 * is the code the receiving system can act on; otherwise whatever coding it did
 * send, which at least identifies the analyte within this laboratory. Null when
 * it sent none — legal, and leaves the name.
 */
export const analyteCode = (observation: FhirResource | null): string | null => {
  const codings = asArray((observation?.code as Record<string, unknown> | undefined)?.coding);
  if (codings.length === 0) return null;

  const loinc = codings.find((coding) => str(coding.system)?.toLowerCase().includes('loinc.org'));
  if (loinc && str(loinc.code)) return str(loinc.code);

  return str(codings.find((coding) => str(coding.code))?.code);
};

/**
 * What to call the analyte on screen. The report's own text is NOT a fallback
 * here — for a panel it names the panel ("Full blood count"), and labelling
 * eight components with the panel's name would make them indistinguishable. The
 * caller supplies that fallback only when there is exactly one analyte, where
 * the two genuinely are the same thing.
 */
export const analyteName = (observation: FhirResource | null): string | null => {
  const code = observation?.code as Record<string, unknown> | undefined;
  if (!code) return null;
  return str(code.text) ?? str(asArray(code.coding).map((coding) => coding.display).find((d) => str(d)));
};

/** The report's narrative fallback, used when an Observation carries no value. */
const conclusionOf = (report: FhirResource): string | null => str(report.conclusion);

/**
 * Collapses one FHIR Observation into the flat fields the HIS stores.
 *
 * The VALUE comes from the pre-extracted text, never from the parsed document —
 * see ReceivedModel. A quantity read off the parsed object has already been
 * through a JavaScript double and lost any trailing zero the laboratory
 * reported.
 */
export const flatten = (observation: IObservation | null, report: FhirResource): IFlatResult => {
  if (!observation) {
    return {
      value: conclusionOf(report),
      unit: null,
      referenceRange: null,
      interpretation: null,
      interpretationCode: null,
    };
  }

  const doc = observation.content;
  let value: string | null = null;
  let unit: string | null = null;

  const quantity = doc.valueQuantity as Record<string, unknown> | undefined;

  if (quantity && observation.valueText !== null) {
    // The text Postgres handed back, exactly as stored.
    value = observation.valueText;
    unit = str(quantity.unit) ?? str(quantity.code);
  } else if (str(doc.valueString)) {
    value = str(doc.valueString);
  } else if (doc.valueCodeableConcept) {
    const concept = doc.valueCodeableConcept as Record<string, unknown>;
    value = str(concept.text) ?? str(asArray(concept.coding).map((c) => c.display).find((d) => str(d)));
  } else if (typeof doc.valueInteger === 'number') {
    // An integer has no fractional part to lose, so the parsed value is exact.
    value = String(doc.valueInteger);
  } else if (typeof doc.valueBoolean === 'boolean') {
    // .NET rendered a bool as "True"/"False"; JavaScript gives "true"/"false".
    // Capitalised to keep the wire value identical for any consumer matching on
    // the string rather than parsing it.
    value = doc.valueBoolean ? 'True' : 'False';
  } else {
    // Some OpenELIS analyses report only a narrative conclusion.
    value = conclusionOf(report);
  }

  const interpretationCodings = codingsOf(doc.interpretation);

  const interpretation =
    str(interpretationCodings.map((c) => str(c.display) ?? str(c.code)).find((x) => str(x))) ??
    str(asArray(doc.interpretation).map((i) => i.text).find((t) => str(t)));

  // Prefer a coding from the HL7 interpretation system, because that is the
  // vocabulary whose AA/HH/LL members mean "critical" rather than merely
  // "abnormal". A laboratory may attach codings from several systems; taking the
  // first one regardless would let a local code masquerade as an HL7 severity.
  const interpretationCode =
    str(
      interpretationCodings
        .filter((c) => str(c.system)?.toLowerCase().includes('observationinterpretation'))
        .map((c) => str(c.code))
        .find((x) => str(x)),
    ) ?? str(interpretationCodings.map((c) => str(c.code)).find((x) => str(x)));

  // The range's own text when the laboratory wrote one, otherwise low-high
  // assembled from the text-extracted bounds so "12.0-16.0" does not become
  // "12-16".
  const ranges = asArray(doc.referenceRange);
  const rangeText = str(ranges.map((r) => r.text).find((t) => str(t)));
  const assembled =
    observation.rangeLowText !== null || observation.rangeHighText !== null
      ? `${observation.rangeLowText ?? ''}-${observation.rangeHighText ?? ''}`.replace(/^-|-$/g, '')
      : null;

  return {
    value,
    unit,
    referenceRange: rangeText ?? (assembled && assembled.length > 0 ? assembled : null),
    interpretation,
    interpretationCode,
  };
};
