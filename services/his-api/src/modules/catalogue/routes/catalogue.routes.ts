import { Router } from 'express';
import { asyncRoute } from '@core/middleware/error.middleware.js';
import { requireAdminToken } from '@core/middleware/admin.middleware.js';
import CatalogueContainer from '../containers/catalogue.container.js';

const controller = CatalogueContainer.catalogueController;

/** Read-only, open: the ordering screen needs it and it changes nothing. */
export const catalogueRouter = Router();
catalogueRouter.get('/', asyncRoute(controller.list));

/**
 * Replaces the menu every doctor orders from, so it carries a token. Manual,
 * like the sync behind it: the technician who enabled a test in the LIS is the
 * person who presses this, and is there to read what changed.
 */
export const catalogueAdminRouter = Router();
catalogueAdminRouter.post('/refresh', requireAdminToken, asyncRoute(controller.refresh));
