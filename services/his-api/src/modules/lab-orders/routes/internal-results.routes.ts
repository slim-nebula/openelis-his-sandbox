import { Router } from 'express';
import { asyncRoute } from '@core/middleware/error.middleware.js';
import LabOrdersContainer from '../containers/lab-orders.container.js';

const router = Router();
router.post('/', asyncRoute(LabOrdersContainer.labOrderController.internalResult));

export default router;
