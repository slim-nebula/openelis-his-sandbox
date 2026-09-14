/**
 * One orderable thing, as the laboratory defines it.
 *
 * Keyed on (loinc, specimenId) rather than LOINC alone, because a LOINC code
 * names WHAT is measured and not what it is measured IN: OpenELIS's catalogue
 * carries 10351-5 on three different tests. See db/bridge/008.
 */
export interface ICatalogueEntry {
  loinc: string;
  openElisTestId: string;
  name: string;
  specimenName: string;
  specimenId: string;
  /**
   * The sample type's LOCAL abbreviation in OpenELIS — "Whole Bld", not
   * "Whole Blood". This is the only string OpenELIS matches a specimen on
   * (type_of_sample.local_abbrev), and getting it wrong binds the wrong test
   * silently. Null when the laboratory has not recorded one, which is a refusal
   * condition rather than a default.
   */
  specimenAbbreviation: string | null;
  resultUnit: string | null;
}

export interface ICatalogueDiff {
  added: string[];
  removed: string[];
  changed: string[];
}

export interface ISyncResult {
  applied: boolean;
  reason: string | null;
  testsBefore: number;
  testsAfter: number;
  diff: ICatalogueDiff;
}

export interface ISyncHistoryRow {
  id: number;
  startedAt: string | null;
  finishedAt: string | null;
  status: string;
  testsBefore: number;
  testsAfter: number;
  added: string | null;
  removed: string | null;
  changed: string | null;
  detail: string | null;
}
