import { Router } from 'express';
import { asyncRoute } from '@core/middleware/error.middleware.js';
import { requireAdminToken } from '@core/middleware/admin.middleware.js';
import CatalogueContainer from '../containers/catalogue.container.js';

const controller = CatalogueContainer.catalogueController;

/**
 * Read-only, and mounted behind the user token in app.ts along with the rest of
 * the clinical API. It changes nothing, but it is the list a doctor orders
 * from, and the screen reading it already holds a token for everything else it
 * does.
 */
export const catalogueRouter = Router();
catalogueRouter.get('/', asyncRoute(controller.list));

/**
 * Replaces the menu every doctor orders from, so it carries a token. Manual,
 * like the sync behind it: the technician who enabled a test in the LIS is the
 * person who presses this, and is there to read what changed.
 */
export const catalogueAdminRouter = Router();
catalogueAdminRouter.post('/refresh', requireAdminToken, asyncRoute(controller.refresh));
