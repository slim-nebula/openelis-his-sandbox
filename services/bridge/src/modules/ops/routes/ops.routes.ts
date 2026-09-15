import { Router } from 'express';
import OpsContainer from '../containers/ops.container.js';

const controller = OpsContainer.controller;

/**
 * Mounted at /ops in app.ts behind requireOpsAccess. Every route here is
 * guarded — there is no open half, unlike /catalogue.
 */
export const opsRouter = Router();

opsRouter.get('/orders', controller.orders);
opsRouter.get('/dead-letters', controller.deadLetterQueue);
opsRouter.get('/reconciliation', controller.reconciliation);

opsRouter.get('/export-status', controller.exportStatus);
opsRouter.get('/export-status/history', controller.exportHistory);
opsRouter.post('/export-status/check', controller.runExportCheck);

opsRouter.post('/retention/sweep', controller.runRetentionSweep);

export default opsRouter;
