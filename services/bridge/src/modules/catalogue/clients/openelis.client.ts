import https from 'node:https';
import axios, { type AxiosInstance } from 'axios';
import { config } from '@config/env.js';
import { logger } from '@config/logger.js';
import type { ICatalogueEntry } from '../types/catalogue.types.js';

/**
 * Reads OpenELIS's own test catalogue over its REST API.
 *
 * This is the only place the bridge talks to OpenELIS as a client rather than
 * as a FHIR peer, and it is deliberately READ-ONLY: the integration reads the
 * laboratory system, it never reshapes it. That matters where the LIS is
 * subject to accreditation.
 *
 * Authentication is the servlet form login, not a token: GET the login page for
 * a CSRF value, POST credentials, keep the session cookie. Because sync is
 * manual and infrequent, a session is acquired per run and discarded, so there
 * is no long-lived credential to refresh and no refresh loop to get wrong.
 *
 * A LIMIT WORTH KNOWING. OpenELIS holds LOINC codes in two places:
 * clinlims.test.loinc, which TaskInterpreterImpl uses to bind an incoming
 * order, and clinlims.test_terminology_mapping, which is what this REST API
 * reports. They can disagree — in this deployment two tests have a terminology
 * mapping but a null test.loinc, so discovery reports them as ambiguous when the
 * order matcher no longer sees a collision.
 *
 * That direction is safe: we under-offer. The unsafe direction would be a test
 * offered here whose test.loinc is null or different, whose orders would then be
 * refused. We cannot rule that out from here, because checking would mean
 * reading OpenELIS's database, which this architecture forbids outright.
 *
 * What makes that acceptable is that the failure is loud rather than silent: an
 * unmatched order comes back REJECTED_BY_LIS with a reason, lands in the order's
 * audit trail, and is covered by the rejection suite. A drifted catalogue
 * therefore shows up as a visibly refused order, not a lost one.
 */
export class OpenElisClient {
  private readonly http: AxiosInstance;

  /**
   * The session, held by hand.
   *
   * axios has no cookie jar and the estate adds no dependency for one, so the
   * Set-Cookie values are kept here and replayed. This is the whole of what a
   * jar would do for a single-host, single-session client: OpenELIS sets
   * JSESSIONID on the login page and expects it back on every subsequent call.
   */
  private cookies = new Map<string, string>();

  constructor() {
    this.http = axios.create({
      baseURL: config.openElis.baseUrl.replace(/\/+$/, '') + '/',
      timeout: config.openElis.timeoutSeconds * 1000,
      // Redirects are NOT followed. The servlet answers an expired session with
      // a redirect to the login page; following it would turn an authentication
      // failure into a 200 carrying HTML, which is exactly the shape that once
      // let an empty catalogue look like a successful read.
      maxRedirects: 0,
      validateStatus: (status) => status < 400,
      // The sandbox serves a self-signed certificate. In a real deployment this
      // must be replaced with proper trust, which is why it is a configuration
      // flag rather than an unconditional bypass.
      httpsAgent: new https.Agent({ rejectUnauthorized: !config.openElis.acceptAnyCertificate }),
    });

    this.http.interceptors.request.use((request) => {
      if (this.cookies.size > 0) {
        request.headers.set(
          'Cookie',
          [...this.cookies].map(([name, value]) => `${name}=${value}`).join('; '),
        );
      }
      return request;
    });

    this.http.interceptors.response.use((response) => {
      this.absorbCookies(response.headers['set-cookie']);
      return response;
    });
  }

  private absorbCookies(setCookie: string[] | undefined): void {
    for (const raw of setCookie ?? []) {
      const [pair] = raw.split(';');
      const index = pair?.indexOf('=') ?? -1;
      if (!pair || index <= 0) continue;
      this.cookies.set(pair.slice(0, index).trim(), pair.slice(index + 1).trim());
    }
  }

  async authenticate(): Promise<void> {
    const loginPage = await this.http.get<string>('LoginPage', { responseType: 'text' });
    const csrf = /name="_csrf"\s+value="([^"]+)"/.exec(String(loginPage.data))?.[1];
    if (!csrf) {
      throw new Error('No _csrf token on the OpenELIS login page; the login form has changed shape.');
    }

    const form = new URLSearchParams({
      loginName: config.openElis.user,
      password: config.openElis.password,
      _csrf: csrf,
    });

    // A failed login is a redirect back to the login page rather than a 4xx, so
    // the status code alone cannot be trusted — hence maxRedirects: 0 and the
    // explicit session check below. 302 is the SUCCESS shape here too, so this
    // one call accepts it.
    const response = await this.http.post('ValidateLogin', form.toString(), {
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      validateStatus: (status) => status < 400 || status === 302,
    });

    const session = await this.getJson<{ authenticated?: boolean }>('session');
    if (session?.authenticated !== true) {
      throw new Error(
        `OpenELIS rejected the credentials for '${config.openElis.user}' ` +
          `(ValidateLogin returned ${response.status}).`,
      );
    }

    logger.info(`Authenticated to OpenELIS as ${config.openElis.user}`);
  }

  /**
   * The servlet answers an expired session with a redirect to the login page,
   * which arrives as HTML and would otherwise surface as an opaque JSON parse
   * error a long way from the cause.
   */
  private async getJson<T>(path: string): Promise<T> {
    const response = await this.http.get(path, { responseType: 'text' });
    const body = typeof response.data === 'string' ? response.data : JSON.stringify(response.data);

    const head = body.trimStart().slice(0, 9).toLowerCase();
    if (head.startsWith('<!doctype') || head.startsWith('<html')) {
      throw new Error(`OpenELIS returned HTML for ${path}; the session is not authenticated.`);
    }

    return JSON.parse(body) as T;
  }

  /**
   * Sample type id -> local abbreviation, the key OpenELIS binds specimens by.
   *
   * rest/sample-types is the only endpoint that exposes local_abbrev; the
   * test-catalog terminology endpoint returns id, name and domain only. Both sit
   * behind hasRole('ADMIN'), which the sync already holds.
   */
  private async sampleTypeAbbreviations(): Promise<Map<string, string>> {
    const response = await this.getJson<{ data?: { id?: string; abbreviation?: string }[] }>(
      'rest/sample-types',
    );

    if (!Array.isArray(response.data)) {
      throw new Error(
        'rest/sample-types returned no data array; cannot resolve specimen abbreviations. ' +
          'Refusing to sync a catalogue whose orders would bind the wrong test.',
      );
    }

    const map = new Map<string, string>();
    for (const row of response.data) {
      if (row.id && row.abbreviation?.trim()) map.set(row.id, row.abbreviation);
    }

    logger.info(`Resolved ${map.size} sample type abbreviations from OpenELIS`);
    return map;
  }

  /**
   * Every test OpenELIS will accept an order for, with the LOINC code and
   * specimen needed to place one.
   *
   * A test is returned only when it is unambiguous on both axes OpenELIS itself
   * uses to bind an incoming order: exactly one LOINC mapping and a resolvable
   * specimen. Anything else would be accepted into the queue and then stall at
   * the accessioning screen waiting for a human to pick the test, which is
   * precisely the behaviour discovery exists to end.
   */
  async orderableTests(): Promise<ICatalogueEntry[]> {
    const listed = await this.getJson<{ rows?: Record<string, unknown>[] }>(
      'rest/test-catalog/tests?page=1&pageSize=1000',
    );
    const rows = listed.rows ?? [];

    const abbreviations = await this.sampleTypeAbbreviations();

    const skipped = new Map<string, number>();
    const skip = (reason: string): void => {
      skipped.set(reason, (skipped.get(reason) ?? 0) + 1);
    };

    const entries: ICatalogueEntry[] = [];

    for (const row of rows) {
      const testId = String(row.testId ?? '');
      if (!testId) continue;
      const listedName = typeof row.name === 'string' ? row.name : testId;

      if (row.active !== true) {
        skip('inactive');
        continue;
      }

      // hasLoinc is on the list row but the code itself is not, so a test
      // without one is discarded before spending two calls on it.
      if (row.hasLoinc !== true) {
        skip('no LOINC code');
        continue;
      }

      const basic = await this.getJson<Record<string, unknown>>(
        `rest/test-catalog/tests/${testId}/basic-info`,
      );
      if (basic.orderable !== true) {
        // The laboratory has this test but has not switched it on for ordering —
        // typically because it owns no analyser for it.
        skip('not orderable');
        continue;
      }

      const terminology = await this.getJson<{
        mappings?: { source?: string; code?: string }[];
        sampleTypes?: { id?: string; name?: string }[];
      }>(`rest/test-catalog/tests/${testId}/terminology`);

      const loincCodes = [
        ...new Set(
          (terminology.mappings ?? [])
            .filter((m) => m.source?.toUpperCase() === 'LOINC')
            .map((m) => m.code)
            .filter((c): c is string => typeof c === 'string' && c.trim().length > 0),
        ),
      ];

      if (loincCodes.length !== 1) {
        skip(loincCodes.length === 0 ? 'no LOINC mapping' : 'several LOINC mappings');
        continue;
      }

      const specimens = (terminology.sampleTypes ?? []).filter(
        (s): s is { id: string; name: string } => Boolean(s.id) && Boolean(s.name),
      );

      if (specimens.length === 0) {
        // Nothing to collect. Not orderable in any meaningful sense.
        skip('no specimen');
        continue;
      }

      const testName = typeof basic.name === 'string' ? basic.name : listedName;

      // ONE ENTRY PER SPECIMEN, rather than discarding a test that runs on more
      // than one.
      //
      // A LOINC code says what is measured, not what it is measured in, so "HIV
      // Viral Load" on plasma and on serum are two orderable things wearing one
      // code. Offering them as one row forced somebody to guess the specimen
      // later; offering them as two lets the DOCTOR choose, which is the only
      // point in the workflow where the answer is known for certain — they know
      // what will be drawn.
      for (const specimen of specimens) {
        const abbreviation = abbreviations.get(specimen.id);

        // No abbreviation means no order we place for this specimen could bind
        // deterministically, so it does not belong on the menu.
        if (!abbreviation?.trim()) {
          skip('specimen has no local abbreviation to resolve by');
          logger.warn(
            `Sample type ${specimen.id} (${specimen.name}) has no local abbreviation; tests on it ` +
              'cannot be bound deterministically and are withheld from the menu',
          );
          continue;
        }

        entries.push({
          loinc: loincCodes[0] as string,
          openElisTestId: testId,
          // Qualified when the test runs on several specimens, so the doctor's
          // search box shows what actually distinguishes them. A bare "HIV Viral
          // Load" three times over is a menu that invites picking the wrong one.
          name: specimens.length === 1 ? testName : `${testName} (${specimen.name})`,
          specimenName: specimen.name,
          specimenId: specimen.id,
          specimenAbbreviation: abbreviation,
          resultUnit: null,
        });
      }
    }

    // Collisions are judged on (LOINC, specimen) — the pair the laboratory
    // actually resolves on — not on the code alone.
    //
    // Several OpenELIS tests share a code: 94547-7 is on four COVID antibody
    // tests, 10351-5 on three HIV viral loads. That alone is no longer
    // disqualifying, because 3.2.2.0 narrows candidates by the sample type the
    // order carries, and we now send one catalogue row per specimen.
    //
    // What remains unresolvable is two tests sharing a code AND a specimen. No
    // information in the order could separate them, so both sides are dropped.
    // Picking one would be guessing which test the laboratory meant, and
    // guessing wrong sends the specimen to the wrong bench.
    const byPair = new Map<string, ICatalogueEntry[]>();
    for (const entry of entries) {
      const key = `${entry.loinc} ${entry.specimenId}`;
      byPair.set(key, [...(byPair.get(key) ?? []), entry]);
    }

    const unique: ICatalogueEntry[] = [];
    for (const [, group] of byPair) {
      const distinctTests = new Set(group.map((entry) => entry.openElisTestId));
      if (distinctTests.size > 1) {
        skipped.set(
          'LOINC and specimen shared with another test',
          (skipped.get('LOINC and specimen shared with another test') ?? 0) + group.length,
        );
        const first = group[0] as ICatalogueEntry;
        logger.warn(
          `LOINC ${first.loinc} on specimen ${first.specimenName} is claimed by ${group.length} ` +
            `tests (${group.map((e) => `${e.openElisTestId} ${e.name}`).join(', ')}); none is ` +
            'orderable from the HIS until the laboratory disambiguates them',
        );
        continue;
      }
      // One test may legitimately list the same specimen twice; the key must not
      // carry duplicates into an insert that now enforces it.
      unique.push(group[0] as ICatalogueEntry);
    }

    logger.info(
      `OpenELIS catalogue: ${unique.length} orderable of ${rows.length} listed ` +
        `(${[...skipped].map(([reason, count]) => `${count} ${reason}`).join(', ')})`,
    );

    return unique;
  }

  /**
   * How OpenELIS thinks its outbound push subscriptions are doing.
   *
   * Reported per endpoint, so the entry naming the bridge is the health of the
   * channel results actually arrive on. maxIntervalMinutes is the cadence
   * OpenELIS intends to keep, which is a better basis for judging staleness than
   * a number we picked.
   */
  async dataExportStatus(): Promise<IExportSubscription[]> {
    const rows = await this.getJson<Record<string, unknown>[]>('rest/DataExportStatus');
    if (!Array.isArray(rows)) return [];

    const num = (value: unknown): number | null => (typeof value === 'number' ? value : null);
    const text = (value: unknown): string | null => (typeof value === 'string' ? value : null);

    return rows.map((row) => ({
      id: row.id === undefined || row.id === null ? '' : String(row.id),
      endpoint: text(row.endpoint) ?? '',
      lastStatus: text(row.lastStatus),
      lastSuccess: text(row.lastSuccess),
      lastAttempt: text(row.lastAttempt),
      failedLast24h: num(row.failedLast24h),
      totalLast24h: num(row.totalLast24h),
      maxIntervalMinutes: num(row.maxIntervalMinutes),
    }));
  }
}

/** One outbound push subscription, as OpenELIS reports it. */
export interface IExportSubscription {
  id: string;
  endpoint: string;
  lastStatus: string | null;
  lastSuccess: string | null;
  lastAttempt: string | null;
  failedLast24h: number | null;
  totalLast24h: number | null;
  maxIntervalMinutes: number | null;
}
