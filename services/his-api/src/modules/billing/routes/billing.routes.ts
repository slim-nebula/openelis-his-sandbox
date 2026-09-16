import { Router } from 'express';
import { asyncRoute } from '@core/middleware/error.middleware.js';
import BillingContainer from '../containers/billing.container.js';

const controller = BillingContainer.billingController;

/**
 * Read-only. Mounted behind the user token in app.ts with the rest of the
 * clinical API — what a test costs is commercial information, and it is listed
 * per test, so it does not become public because it is a GET.
 *
 * There is deliberately no write endpoint. The map is deployment
 * configuration, not something a running system edits: it is loaded by
 * migration or by the hospital's own tooling, reviewed before go-live, and
 * changed the same way a price list is changed. An API that let it be edited
 * at runtime would make "who repriced this test, and when" unanswerable.
 */
export const billingRouter = Router();
billingRouter.get('/map', asyncRoute(controller.list));
billingRouter.get('/reconciliation', asyncRoute(controller.reconciliation));

export default billingRouter;
