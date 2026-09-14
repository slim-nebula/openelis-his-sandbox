import type { Request, Response } from 'express';
import type { CatalogueModel } from '../models/catalogue.model.js';

export class CatalogueController {
  constructor(private readonly catalogue: CatalogueModel) {}

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
}
