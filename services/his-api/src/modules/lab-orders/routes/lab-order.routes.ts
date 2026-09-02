import { Router } from 'express';
import { asyncRoute } from '@core/middleware/error.middleware.js';
import { auditAccess } from '@core/audit/audit.middleware.js';
import LabOrdersContainer from '../containers/lab-orders.container.js';

const router = Router();
const controller = LabOrdersContainer.labOrderController;

router.post('/', auditAccess('laborder.create', 'C'), asyncRoute(controller.create));

// The bedside draw. Declared BEFORE '/:id' so that the literal path segment is
// not swallowed by the parameter route — Express matches in declaration order,
// and '/:id' would otherwise take 'LAB-.../collection' as an id.
//
// Audited as an update rather than a read: it records a clinical event and
// releases the order to the laboratory, which is the most consequential thing a
// ward does to an order after placing it.
router.post(
  '/:orderNumber/collection',
  auditAccess('laborder.collect', 'U', (req) =>
    req.params.orderNumber ? `ServiceRequest/${req.params.orderNumber}` : undefined),
  asyncRoute(controller.recordCollection),
);

router.get(
  '/:id',
  auditAccess('laborder.read', 'R', (req) =>
    req.params.id ? `ServiceRequest/${req.params.id}` : undefined),
  asyncRoute(controller.getById),
);

export default router;
