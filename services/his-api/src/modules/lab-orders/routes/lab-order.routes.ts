import { Router } from 'express';
import { asyncRoute } from '@core/middleware/error.middleware.js';
import { auditAccess } from '@core/audit/audit.middleware.js';
import LabOrdersContainer from '../containers/lab-orders.container.js';

const router = Router();
const controller = LabOrdersContainer.labOrderController;

router.post('/', auditAccess('laborder.create', 'C'), asyncRoute(controller.create));
router.get(
  '/:id',
  auditAccess('laborder.read', 'R', (req) =>
    req.params.id ? `ServiceRequest/${req.params.id}` : undefined),
  asyncRoute(controller.getById),
);

export default router;
