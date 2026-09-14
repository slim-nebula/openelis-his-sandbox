import { Router } from 'express';
import CatalogueContainer from '../containers/catalogue.container.js';

const controller = CatalogueContainer.controller;

/**
 * GET /catalogue — open, read-only, no patient data.
 *
 * Mounted bare in app.ts. Everything that CHANGES the menu lives on the
 * guarded router below.
 */
export const catalogueRouter = Router();
catalogueRouter.get('/', controller.list);

/**
 * The administrative half: /catalogue/syncs and /catalogue/sync. Mounted behind
 * requireOpsAccess, because an unauthenticated caller could otherwise empty the
 * doctor's test menu with one request.
 */
export const catalogueAdminRouter = Router();
catalogueAdminRouter.get('/syncs', controller.history);

export default catalogueRouter;
