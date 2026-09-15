import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

/**
 * Imported dynamically, and that is not a workaround — it is the module's
 * contract showing through. `config` is evaluated at import time and throws on
 * a missing BRIDGE_DB_CONNECTION, deliberately, so that a misconfigured
 * deployment dies at startup rather than at the first request. A static import
 * here would hoist above any assignment and take the whole file down with it.
 */
process.env.BRIDGE_DB_CONNECTION ??= 'Host=localhost;Database=t;Username=t;Password=t';
const { parseDatabaseConnection } = await import('./env.js');

/**
 * BRIDGE_DB_CONNECTION predates this service being written in Node: compose
 * builds it as an Npgsql string, which node-postgres cannot parse at all — and
 * does not fail loudly about. It treats the whole thing as a HOST NAME, and the
 * service simply never connects.
 *
 * That is the failure these pin. It cost a debugging session during the rewrite,
 * and it would cost another if someone decided the parser looked redundant.
 */
describe('parseDatabaseConnection', () => {
  test('parses the Npgsql shape compose actually builds', () => {
    const parsed = parseDatabaseConnection(
      'Host=his-db.external;Port=5432;Database=bridge_sandbox;Username=bridge_app;Password=s3cret',
    );
    assert.deepEqual(parsed, {
      host: 'his-db.external',
      port: 5432,
      database: 'bridge_sandbox',
      user: 'bridge_app',
      password: 's3cret',
    });
  });

  test('ignores the trailing options compose appends', () => {
    // The real value ends with ";Include Error Detail=true", which is an Npgsql
    // setting with no node-postgres equivalent and must simply be skipped.
    const parsed = parseDatabaseConnection(
      'Host=h;Port=5432;Database=d;Username=u;Password=p;Include Error Detail=true',
    );
    assert.equal(parsed.database, 'd');
    assert.equal(parsed.password, 'p');
    assert.ok(!('include error detail' in parsed));
  });

  test('keys are case-insensitive, as Npgsql treats them', () => {
    const parsed = parseDatabaseConnection('HOST=h;PORT=6000;DATABASE=d;USERNAME=u;PASSWORD=p');
    assert.equal(parsed.host, 'h');
    assert.equal(parsed.port, 6000);
  });

  test('accepts "User ID" as well as "Username"', () => {
    assert.equal(parseDatabaseConnection('Host=h;User ID=alice;Password=p').user, 'alice');
  });

  test('hands a URL straight to pg rather than taking it apart', () => {
    // Parsing a URL ourselves would mean URL-decoding a generated password,
    // which is a real trap in the other direction.
    const raw = 'postgres://user:p%40ss@host:5432/db';
    assert.deepEqual(parseDatabaseConnection(raw), { connectionString: raw });
  });

  test('a password containing = survives, because only the FIRST = splits', () => {
    const parsed = parseDatabaseConnection('Host=h;Username=u;Password=a=b=c');
    assert.equal(parsed.password, 'a=b=c');
  });

  test('tolerates surrounding whitespace', () => {
    const parsed = parseDatabaseConnection(' Host = h ; Port = 5432 ; Username = u ');
    assert.equal(parsed.host, 'h');
    assert.equal(parsed.user, 'u');
  });

  test('missing fields become empty rather than undefined, so pg does not guess', () => {
    const parsed = parseDatabaseConnection('Host=h');
    assert.equal(parsed.database, '');
    assert.equal(parsed.user, '');
    assert.equal(parsed.password, '');
    assert.equal(parsed.port, 5432);
  });
});
