import { Router } from 'express';
import { asyncRoute } from '@core/middleware/error.middleware.js';
import LabOrdersContainer from '../containers/lab-orders.container.js';

const router = Router();
const controller = LabOrdersContainer.labOrderController;

router.post('/', asyncRoute(controller.create));
router.get('/:id', asyncRoute(controller.getById));

export default router;
