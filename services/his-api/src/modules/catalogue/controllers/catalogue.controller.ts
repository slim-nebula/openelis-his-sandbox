import type { Request, Response } from 'express';
import type { CatalogueService } from '../services/catalogue.service.js';

export class CatalogueController {
  constructor(private readonly catalogue: CatalogueService) {}

  list = async (_req: Request, res: Response): Promise<void> => {
    res.json(await this.catalogue.list());
  };

  refresh = async (_req: Request, res: Response): Promise<void> => {
    const result = await this.catalogue.refresh();
    // 409, not 500: the request was valid and the guard did its job. The body
    // says why, which is what the operator needs in order to decide what next.
    res.status(result.applied ? 200 : 409).json(result);
  };
}
