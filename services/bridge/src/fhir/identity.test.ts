import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { deterministicUuid, practitionerIdFor, specimenIdFor, taskIdFor } from './identity.js';

/**
 * The highest-consequence function in the service, and the one whose failure is
 * silent: a drifted implementation does not error, it mints a NEW Practitioner
 * for every clinician on every order, permanently, in the laboratory's own
 * provider records.
 *
 * These vectors are not invented. Each was verified by hand during the rewrite
 * against an independent implementation or against data the .NET service had
 * already written, and they are recorded here so the next person to touch this
 * file finds out immediately rather than in six months.
 */
describe('deterministicUuid', () => {
  test('matches the published RFC 4122 v5 vector for python.org', () => {
    // From Python's own uuid documentation, and reproducible with
    //   python3 -c "import uuid; print(uuid.uuid5(uuid.NAMESPACE_DNS,'python.org'))"
    assert.equal(deterministicUuid('python.org'), '886313e1-3b8a-5372-9b90-0c9aee199e5d');
  });

  test('reproduces an id the .NET bridge actually wrote', () => {
    // bridge.order_tracking row for order LAB-20260824-137539B5, which the C#
    // service published before this rewrite existed. If this ever changes, the
    // rewrite has silently stopped agreeing with the data already in the
    // laboratory.
    assert.equal(
      deterministicUuid('task|137539b5-2690-46ea-b808-bcbc0d31352c'),
      '07e60d38-f066-5d30-8c6a-9d9acd56b930',
    );
  });

  test('is stable across calls', () => {
    assert.equal(deterministicUuid('practitioner|9001'), deterministicUuid('practitioner|9001'));
  });

  test('distinguishes names that differ only in case or separator', () => {
    const base = deterministicUuid('task|abc');
    assert.notEqual(base, deterministicUuid('Task|abc'));
    assert.notEqual(base, deterministicUuid('task:abc'));
  });

  test('sets the version and variant bits RFC 4122 requires', () => {
    for (const name of ['a', 'task|1', 'practitioner|9001', '']) {
      const uuid = deterministicUuid(name);
      assert.match(uuid, /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    }
  });
});

/**
 * The PREFIXES are as much a contract as the algorithm. Changing "task|" to
 * "Task|" would republish every order in the system under new ids, and nothing
 * would report an error.
 */
describe('the three id derivations', () => {
  const orderId = '137539b5-2690-46ea-b808-bcbc0d31352c';

  test('task, specimen and practitioner ids use their documented names', () => {
    assert.equal(taskIdFor(orderId), deterministicUuid(`task|${orderId}`));
    assert.equal(specimenIdFor(orderId), deterministicUuid(`specimen|${orderId}`));
    assert.equal(practitionerIdFor('9001'), deterministicUuid('practitioner|9001'));
  });

  test('the same order does not produce the same id for task and specimen', () => {
    assert.notEqual(taskIdFor(orderId), specimenIdFor(orderId));
  });

  test('one clinician is one Practitioner, however many orders they place', () => {
    assert.equal(practitionerIdFor('9001'), practitionerIdFor('9001'));
    assert.notEqual(practitionerIdFor('9001'), practitionerIdFor('9002'));
  });
});
