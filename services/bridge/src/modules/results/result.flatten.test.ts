import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { analyteCode, analyteName, flatten } from './result.flatten.js';
import type { FhirResource } from '@fhir/types.js';
import type { IObservation } from './models/received.model.js';

const observation = (content: Record<string, unknown>, extra: Partial<IObservation> = {}): IObservation => ({
  content: { resourceType: 'Observation', ...content } as FhirResource,
  receivedAt: null,
  valueText: null,
  rangeLowText: null,
  rangeHighText: null,
  ...extra,
});

const report = (content: Record<string, unknown> = {}): FhirResource =>
  ({ resourceType: 'DiagnosticReport', ...content }) as FhirResource;

/**
 * THE POINT OF THIS FILE.
 *
 * JavaScript has one number type. Postgres keeps a JSON 1.10 as 1.10; a
 * JSON.parse/stringify round trip returns 1.1. For a laboratory result that
 * trailing zero states the precision of the measurement, so the value is read
 * out of the database as TEXT and must never be taken off the parsed document.
 *
 * If someone later "simplifies" this by reading content.valueQuantity.value,
 * every one of these fails.
 */
describe('decimal precision', () => {
  test('a trailing zero survives, because the value comes from the text column', () => {
    const flat = flatten(
      observation({ valueQuantity: { value: 1.1, unit: 'mmol/L' } }, { valueText: '1.10' }),
      report(),
    );
    assert.equal(flat.value, '1.10', 'the analyser reported 1.10, not 1.1');
    assert.equal(flat.unit, 'mmol/L');
  });

  test('an integral result keeps the precision the laboratory stated', () => {
    const flat = flatten(
      observation({ valueQuantity: { value: 4, unit: 'mmol/L' } }, { valueText: '4.0' }),
      report(),
    );
    assert.equal(flat.value, '4.0', 'a potassium of 4.0 is not the same statement as 4');
  });

  test('the reference range is assembled from text bounds too', () => {
    const flat = flatten(
      observation(
        { valueQuantity: { value: 12.9 }, referenceRange: [{ low: { value: 12 }, high: { value: 16 } }] },
        { valueText: '12.9', rangeLowText: '12.0', rangeHighText: '16.0' },
      ),
      report(),
    );
    assert.equal(flat.referenceRange, '12.0-16.0', 'not 12-16');
  });

  test("the laboratory's own range text wins over assembly", () => {
    const flat = flatten(
      observation(
        { valueQuantity: { value: 1 }, referenceRange: [{ text: 'Negative' }] },
        { valueText: '1', rangeLowText: '0', rangeHighText: '2' },
      ),
      report(),
    );
    assert.equal(flat.referenceRange, 'Negative');
  });

  test('a one-sided range does not become a dangling hyphen', () => {
    const low = flatten(
      observation({ valueQuantity: { value: 5 }, referenceRange: [{ low: { value: 3 } }] }, { valueText: '5', rangeLowText: '3.0' }),
      report(),
    );
    assert.equal(low.referenceRange, '3.0');
  });
});

describe('the value[x] types OpenELIS actually sends', () => {
  test('valueString', () => {
    assert.equal(flatten(observation({ valueString: 'Not detected' }), report()).value, 'Not detected');
  });

  test('valueCodeableConcept prefers text, then a coding display', () => {
    assert.equal(
      flatten(observation({ valueCodeableConcept: { text: 'Reactive' } }), report()).value,
      'Reactive',
    );
    assert.equal(
      flatten(
        observation({ valueCodeableConcept: { coding: [{ display: 'Non-reactive' }] } }),
        report(),
      ).value,
      'Non-reactive',
    );
  });

  test('valueInteger is exact, so the parsed number is safe', () => {
    assert.equal(flatten(observation({ valueInteger: 42 }), report()).value, '42');
  });

  test('valueBoolean keeps the capitalised wire form the .NET service emitted', () => {
    assert.equal(flatten(observation({ valueBoolean: true }), report()).value, 'True');
    assert.equal(flatten(observation({ valueBoolean: false }), report()).value, 'False');
  });

  test('an Observation with no value falls back to the report narrative', () => {
    // Some OpenELIS analyses report only a conclusion.
    const flat = flatten(observation({}), report({ conclusion: 'Specimen unsuitable' }));
    assert.equal(flat.value, 'Specimen unsuitable');
  });

  test('no Observation at all still carries the narrative', () => {
    assert.equal(flatten(null, report({ conclusion: 'See comment' })).value, 'See comment');
  });
});

/**
 * A local code must not masquerade as an HL7 severity. AA/HH/LL in the HL7
 * vocabulary mean CRITICAL; the same letters elsewhere mean whatever that
 * laboratory decided.
 */
describe('interpretation', () => {
  const hl7 = 'http://terminology.hl7.org/CodeSystem/v3-ObservationInterpretation';

  test('prefers a coding from the HL7 interpretation system', () => {
    const flat = flatten(
      observation({
        valueQuantity: { value: 1 },
        interpretation: [
          { coding: [{ system: 'http://lab.local/flags', code: 'HH', display: 'House high' }] },
          { coding: [{ system: hl7, code: 'H', display: 'High' }] },
        ],
      }, { valueText: '1' }),
      report(),
    );
    assert.equal(flat.interpretationCode, 'H', 'the HL7 code, not the local HH');
  });

  test('falls back to any coding when the laboratory sent no HL7 one', () => {
    const flat = flatten(
      observation({ valueString: 'x', interpretation: [{ coding: [{ system: 'http://lab.local', code: 'ABN' }] }] }),
      report(),
    );
    assert.equal(flat.interpretationCode, 'ABN');
  });

  test('the label comes from display, then code, then text', () => {
    assert.equal(
      flatten(observation({ valueString: 'x', interpretation: [{ coding: [{ system: hl7, code: 'N', display: 'Normal' }] }] }), report()).interpretation,
      'Normal',
    );
    assert.equal(
      flatten(observation({ valueString: 'x', interpretation: [{ text: 'Slightly raised' }] }), report()).interpretation,
      'Slightly raised',
    );
  });

  test('no interpretation is null rather than empty string', () => {
    const flat = flatten(observation({ valueString: 'x' }), report());
    assert.equal(flat.interpretation, null);
    assert.equal(flat.interpretationCode, null);
  });
});

describe('analyte identity', () => {
  test('prefers the LOINC coding, because that is what a receiver can act on', () => {
    const doc = {
      resourceType: 'Observation',
      code: {
        coding: [
          { system: 'http://openelis-global.org/test', code: 'HGB-LOCAL' },
          { system: 'http://loinc.org', code: '718-7', display: 'Haemoglobin' },
        ],
      },
    } as FhirResource;
    assert.equal(analyteCode(doc), '718-7');
  });

  test('falls back to a local coding rather than dropping the analyte', () => {
    const doc = {
      resourceType: 'Observation',
      code: { coding: [{ system: 'http://openelis-global.org/test', code: 'HGB-LOCAL' }] },
    } as FhirResource;
    assert.equal(analyteCode(doc), 'HGB-LOCAL');
  });

  test('no coding at all is null, which is legal and leaves the name', () => {
    assert.equal(analyteCode({ resourceType: 'Observation' } as FhirResource), null);
    assert.equal(analyteCode(null), null);
  });

  test('the name prefers code.text, then a coding display', () => {
    assert.equal(
      analyteName({ resourceType: 'Observation', code: { text: 'Haemoglobin' } } as FhirResource),
      'Haemoglobin',
    );
    assert.equal(
      analyteName({ resourceType: 'Observation', code: { coding: [{ display: 'Hb' }] } } as FhirResource),
      'Hb',
    );
  });

  test('the report name is NEVER an analyte fallback here', () => {
    // For a panel the report names the panel, and labelling eight components
    // "Full blood count" would make them indistinguishable. The caller supplies
    // that fallback only when there is exactly one analyte.
    assert.equal(analyteName({ resourceType: 'Observation' } as FhirResource), null);
  });
});
