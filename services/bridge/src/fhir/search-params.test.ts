import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { tokenOne, tokenSet } from './search-params.js';

/**
 * THE POINT OF THIS FILE.
 *
 * OpenELIS's remote poll asks for Tasks with status `requested` OR `received`.
 * Both of the two forms it might send that in used to collapse to a single
 * value, and the result was not an error — it was an empty searchset, logged
 * as "0 match(es)", indistinguishable from a quiet queue.
 *
 * The cost was an order acknowledged as `received` and then not imported:
 * invisible to every later poll, holding no lease, counted by nothing, and
 * showing SENT_TO_LIS to the clinician for ever.
 *
 * If someone later "simplifies" this back to a single value, these fail.
 */
describe('tokenSet — a status parameter naming several values', () => {
  test('accepts the FHIR comma form, which used to match the literal string', () => {
    assert.deepEqual(tokenSet('requested,received'), ['requested', 'received']);
  });

  test('accepts the repeated form, whose second value used to be dropped', () => {
    assert.deepEqual(tokenSet(['requested', 'received']), ['requested', 'received']);
  });

  test('a single value still behaves exactly as before', () => {
    assert.deepEqual(tokenSet('requested'), ['requested']);
  });

  test('absent is null — "do not filter", not "match nothing"', () => {
    // The distinction is load-bearing: the SQL reads null as "skip this
    // predicate". An empty array would filter everything out instead.
    assert.equal(tokenSet(undefined), null);
    assert.equal(tokenSet(null), null);
    assert.equal(tokenSet([]), null);
  });

  test('a blank or comma-only value is null, not an empty-string match', () => {
    assert.equal(tokenSet(''), null);
    assert.equal(tokenSet(','), null);
    assert.equal(tokenSet('   '), null);
  });

  test('a trailing or doubled comma is a typo, not a request to match nothing', () => {
    assert.deepEqual(tokenSet('requested,'), ['requested']);
    assert.deepEqual(tokenSet('requested,,received'), ['requested', 'received']);
  });

  test('surrounding whitespace is trimmed, as a hand-typed query carries it', () => {
    assert.deepEqual(tokenSet(' requested , received '), ['requested', 'received']);
  });

  test('order is preserved, because the caller reads it back in the log line', () => {
    assert.deepEqual(tokenSet('received,requested'), ['received', 'requested']);
  });

  test('non-string junk is ignored rather than coerced', () => {
    // Express can hand back nested objects for bracketed query syntax; a
    // stringified "[object Object]" would become a status nothing matches.
    assert.equal(tokenSet({ evil: true }), null);
    assert.deepEqual(tokenSet(['requested', 42, null] as unknown), ['requested']);
  });
});

describe('tokenOne — a parameter carrying exactly one value', () => {
  test('takes the first of a repeated parameter', () => {
    assert.equal(tokenOne(['a', 'b']), 'a');
  });

  test('does NOT split on commas — an owner reference may legitimately contain one', () => {
    assert.equal(tokenOne('Organization/a,b'), 'Organization/a,b');
  });

  test('absent or non-string is null', () => {
    assert.equal(tokenOne(undefined), null);
    assert.equal(tokenOne([]), null);
    assert.equal(tokenOne(7), null);
  });
});
