import type { Request, Response } from 'express';
import type { BillingService } from '../services/billing.service.js';

export class BillingController {
  constructor(private readonly service: BillingService) {}

  /** The map as it stands. What a deployment reviews before go-live. */
  list = async (_req: Request, res: Response): Promise<void> => {
    res.json(await this.service.list());
  };

  /**
   * Does the map still describe the menu? Read-only and side-effect free, so it
   * is safe to run from a cron, a deployment gate, or a person at 3am.
   */
  reconciliation = async (_req: Request, res: Response): Promise<void> => {
    res.json(await this.service.reconcile());
  };
}

export default BillingController;
