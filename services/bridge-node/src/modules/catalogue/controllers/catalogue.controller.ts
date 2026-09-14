import type { Request, Response } from 'express';
import { catalogueDiscoveryConfigured } from '@config/env.js';
import { problemResponse } from '@core/middleware/error.js';
import type { CatalogueModel } from '../models/catalogue.model.js';
import type { CatalogueSync } from '../catalogue.sync.js';

export class CatalogueController {
  constructor(
    private readonly catalogue: CatalogueModel,
    private readonly sync: CatalogueSync,
  ) {}

  /**
   * The cached test menu, served from the database and never live.
   *
   * The ordering screen must not go blank because OpenELIS is restarting, and
   * `syncedAt` lets the caller show how old the menu is rather than pretend it
   * cannot age.
   *
   * Deliberately open — no token. It is the laboratory's list of orderable
   * tests, read service-to-service by his-api, and it holds no patient data at
   * all. The endpoint that CHANGES it is behind a token. `make negative`
   * asserts this one stays open, because that is the failure this kind of
   * change actually causes.
   */
  list = async (_req: Request, res: Response): Promise<void> => {
    const [syncedAt, tests] = await Promise.all([
      this.catalogue.syncedAt(),
      this.catalogue.all(),
    ]);

    res.json({ syncedAt, count: tests.length, tests });
  };

  history = async (_req: Request, res: Response): Promise<void> => {
    res.json(await this.catalogue.syncHistory());
  };

  /**
   * Re-reads the menu from OpenELIS.
   *
   * Manual, because a clinic changes its menu when it commissions an analyser —
   * a few times a year — and a human pressing this is a human who can read the
   * diff. `force=true` overrides the shrink guard for a genuine large
   * withdrawal.
   */
  runSync = async (req: Request, res: Response): Promise<void> => {
    if (!catalogueDiscoveryConfigured()) {
      problemResponse(
        res,
        501,
        'Catalogue discovery is not configured. Set OE_REST_BASE_URL, OE_SERVICE_USER and OE_SERVICE_PASSWORD.',
      );
      return;
    }

    const force = req.query['force'] === 'true';
    const result = await this.sync.run(force);

    // A rejected sync is not an error in the caller: the request was valid and
    // the guard did its job. 409 says "I did not apply this", and the body says
    // why, which is what the operator needs to decide whether to force it.
    res.status(result.applied ? 200 : 409).json(result);
  };
}
