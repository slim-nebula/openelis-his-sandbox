import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { mapOrder, splitName } from './order.mapper.js';
import type { IHisOrder } from './types/order.types.js';

/**
 * Name splitting is crude on purpose — the HIS stores one display string, and
 * any cleverer rule would be a guess about naming conventions this sandbox has
 * no business making. What these pin is that it stays crude, and above all that
 * it stays UNSANITISED.
 */
describe('splitName', () => {
  test('takes the last token as the family name', () => {
    assert.deepEqual(splitName('Amadou Konate'), { given: 'Amadou', family: 'Konate' });
  });

  test('keeps everything before the last token as given', () => {
    assert.deepEqual(splitName('Marie Claire Diallo'), { given: 'Marie Claire', family: 'Diallo' });
  });

  test('a single token is the family name, because that is what OpenELIS shows', () => {
    assert.deepEqual(splitName('Konate'), { given: null, family: 'Konate' });
  });

  test('collapses repeated and surrounding whitespace', () => {
    assert.deepEqual(splitName('  Amadou   Konate  '), { given: 'Amadou', family: 'Konate' });
  });

  /**
   * DIGITS ARE NOT STRIPPED, and this test exists to stop someone "fixing" that.
   *
   * OpenELIS validates provider names against lastNameCharset — letters, space,
   * apostrophe, dot and hyphen, no digits — and refuses the order when the
   * accessioner saves. Stripping them here to slip past that would alter a
   * clinician's identity in a clinical record to avoid an error message. The
   * laboratory refusing a malformed name is the correct outcome; the fix belongs
   * in the HIS that holds it. See upstream issue 07.
   */
  test('does NOT strip digits, however tempting', () => {
    assert.deepEqual(splitName('Ward 3 Locum'), { given: 'Ward 3', family: 'Locum' });
    assert.deepEqual(splitName('Probe233301'), { given: null, family: 'Probe233301' });
  });

  test('keeps accents and hyphens intact', () => {
    assert.deepEqual(splitName('Fatou Diallo-Sow'), { given: 'Fatou', family: 'Diallo-Sow' });
    assert.deepEqual(splitName('Amadou Konaté'), { given: 'Amadou', family: 'Konaté' });
  });
});

const order = (overrides: Partial<IHisOrder> = {}): IHisOrder => ({
  orderId: '137539b5-2690-46ea-b808-bcbc0d31352c',
  orderNumber: 'LAB-20260824-137539B5',
  testCode: '10351-5|DBS',
  testName: 'HIV VIRAL LOAD',
  loincCode: '10351-5',
  specimenType: 'DBS',
  specimenSnomed: null,
  resultUnit: null,
  orderStatus: 'AWAITING_COLLECTION',
  orderingProvider: 'Amadou Konate',
  orderingProviderId: '1',
  orderingProviderHcpId: '9001',
  orderingProviderLicense: 'ML-9001',
  facilityCode: 'FAC-001',
  priority: 'routine',
  patientClass: 'OUTPATIENT',
  collectedAt: null,
  createdAt: '2026-08-24T10:00:00.000Z',
  patient: {
    patientId: '11111111-1111-1111-1111-111111111111',
    firstName: 'Amina',
    lastName: 'Traore',
    sex: 'F',
    dateOfBirth: '1988-04-17',
    phone: '+22370000001',
    nationalId: 'NID-000001',
  },
  ...overrides,
});

const OWNER = 'Organization/26a13c4c-ce5f-48d9-9283-2a2d1d2c9ce4';

describe('mapOrder', () => {
  test('ServiceRequest.id is the ORDER NUMBER, not a uuid', () => {
    // OpenELIS's Incoming Orders view reads ServiceRequest/{external_id}
    // straight out of its own FHIR store. With a uuid that read 404s and the
    // lab user sees "error in data collection" with no test name — while order
    // IMPORT still works, because that path follows Task.basedOn instead. Which
    // is exactly why it stayed invisible from this side.
    const mapped = mapOrder(order(), OWNER, 'Sandbox Hospital Lab', 'DBS');
    assert.equal(mapped.serviceRequest.id, 'LAB-20260824-137539B5');
  });

  test('Task.owner is an Organization reference, never a Practitioner', () => {
    // LabOrderSearchProvider attributes the order to the owner whenever the
    // reference contains "Practitioner", which hides the real ordering clinician
    // behind the routing identity.
    const mapped = mapOrder(order(), OWNER, 'Sandbox Hospital Lab', 'DBS');
    const owner = mapped.task.owner as { reference: string };
    assert.equal(owner.reference, OWNER);
    assert.ok(!owner.reference.includes('Practitioner'));
  });

  test('the specimen carries the local abbreviation OpenELIS resolves by', () => {
    const mapped = mapOrder(order(), OWNER, 'Sandbox Hospital Lab', 'Whole Bld');
    const codings = (mapped.specimen.type as { coding: Record<string, string>[] }).coding;
    const oe = codings.find((c) => c.system === 'http://openelis-global.org/sampleType');
    assert.equal(oe?.code, 'Whole Bld', 'the abbreviation, not the display name');
  });

  test('with NO abbreviation it emits no OpenELIS coding at all, rather than guessing', () => {
    // A wrong code binds the wrong test confidently; an absent one leaves the
    // decision with the laboratory.
    const mapped = mapOrder(order(), OWNER, 'Sandbox Hospital Lab', null);
    const codings = (mapped.specimen.type as { coding: Record<string, string>[] }).coding;
    assert.equal(codings.filter((c) => c.system?.includes('openelis-global')).length, 0);
  });

  test('an order with no clinical identity gets NO requester, not an invented one', () => {
    const mapped = mapOrder(
      order({ orderingProviderHcpId: null }),
      OWNER,
      'Sandbox Hospital Lab',
      'DBS',
    );
    assert.equal(mapped.orderingClinician, null);
    assert.equal(mapped.serviceRequest.requester, undefined);
  });

  test('the Practitioner is keyed on the clinician, not the account or the name', () => {
    const a = mapOrder(order(), OWNER, 'Lab', 'DBS').orderingClinician;
    const spelledDifferently = mapOrder(
      order({ orderingProvider: 'A. Konate', orderingProviderId: '77' }),
      OWNER,
      'Lab',
      'DBS',
    ).orderingClinician;
    assert.equal(a?.id, spelledDifferently?.id, 'same hcpId is the same clinician');
  });

  test('the Practitioner id is a uuid, because OpenELIS calls UUID.fromString on it', () => {
    const mapped = mapOrder(order(), OWNER, 'Sandbox Hospital Lab', 'DBS');
    assert.match(String(mapped.orderingClinician?.id), /^[0-9a-f-]{36}$/);
  });

  test('collection time is omitted entirely when the ward drew nothing', () => {
    // An outpatient specimen is drawn in the laboratory; an empty element would
    // suggest we had something to say about it and lost it.
    const outpatient = mapOrder(order(), OWNER, 'Lab', 'DBS');
    assert.equal(outpatient.specimen.collection, undefined);

    const inpatient = mapOrder(
      order({ collectedAt: '2026-08-24T09:30:00.000Z' }),
      OWNER,
      'Lab',
      'DBS',
    );
    assert.deepEqual(inpatient.specimen.collection, {
      collectedDateTime: '2026-08-24T09:30:00.000Z',
    });
  });

  test('receivedTime is never asserted — receipt is the laboratory’s to observe', () => {
    const mapped = mapOrder(order({ collectedAt: '2026-08-24T09:30:00.000Z' }), OWNER, 'Lab', 'DBS');
    assert.equal(mapped.specimen.receivedTime, undefined);
  });

  test('the Practitioner is published BEFORE the ServiceRequest that references it', () => {
    // OpenELIS dereferences ServiceRequest.requester while importing, so the
    // Practitioner has to be readable before the ServiceRequest is visible.
    const all = mapOrder(order(), OWNER, 'Lab', 'DBS').all.map((r) => r.resourceType);
    assert.ok(all.indexOf('Practitioner') < all.indexOf('ServiceRequest'));
    assert.equal(all[all.length - 1], 'Task', 'the Task is published last');
  });

  test('priority maps the laboratory vocabulary, defaulting to routine', () => {
    const priorityOf = (p: string): unknown => mapOrder(order({ priority: p }), OWNER, 'L', 'DBS').task.priority;
    assert.equal(priorityOf('stat'), 'stat');
    assert.equal(priorityOf('urgent'), 'stat');
    assert.equal(priorityOf('asap'), 'asap');
    assert.equal(priorityOf('whatever'), 'routine');
  });
});
