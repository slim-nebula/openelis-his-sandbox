import { Router } from 'express';
import { asyncRoute } from '@core/middleware/error.middleware.js';
import LabOrdersContainer from '../containers/lab-orders.container.js';

/** Bridge-facing, reached directly over the sandbox network. Not routed by Kong. */
const router = Router();
const controller = LabOrdersContainer.labOrderController;

router.get('/:id', asyncRoute(controller.internalPayload));

export default router;
