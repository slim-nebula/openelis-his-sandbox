import { logger } from '@config/logger.js';
import { fetchDiscoveredCatalogue } from '@shared/clients/bridge.client.js';
import type { CatalogueModel, ICatalogueEntry } from '../models/catalogue.model.js';

export interface IRefreshResult {
  applied: boolean;
  reason: string | null;
  offered: number;
  upserted: number;
  deactivated: number;
}

/**
 * The HIS keeps a copy of the menu rather than calling the bridge on every page
 * load, for two reasons that both matter more than freshness: lab_orders
 * references this table, so a test that has ever been ordered can never be
 * dropped; and a doctor opening the ordering screen while the bridge restarts
 * should see yesterday's menu, not an empty list.
 *
 * This is a projection, not a second opinion. Nothing here decides what is
 * orderable — it only remembers what OpenELIS last said.
 */
export class CatalogueService {
  constructor(private readonly catalogue: CatalogueModel) {}

  list(): Promise<ICatalogueEntry[]> {
    return this.catalogue.listActive();
  }

  async refresh(): Promise<IRefreshResult> {
    const tests = await fetchDiscoveredCatalogue();

    // An empty menu is refused here as well as in the bridge. The bridge guards
    // against a bad read from OpenELIS; this guards against the bridge being
    // freshly deployed with nothing synced yet, which would otherwise
    // deactivate every test in the HIS with one button press.
    if (tests.length === 0) {
      logger.warn('Bridge returned an empty catalogue; leaving the HIS menu untouched');
      return {
        applied: false,
        reason: 'the bridge has no catalogue yet — run a sync there first',
        offered: 0,
        upserted: 0,
        deactivated: 0,
      };
    }

    const outcome = await this.catalogue.mirror(tests);
    logger.info(
      `Catalogue mirror refreshed: ${outcome.offered} offered, ${outcome.deactivated} withdrawn (was ${outcome.before})`,
    );
    return {
      applied: true,
      reason: null,
      offered: outcome.offered,
      upserted: outcome.upserted,
      deactivated: outcome.deactivated,
    };
  }
}
