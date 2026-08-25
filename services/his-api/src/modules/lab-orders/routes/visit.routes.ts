import { Router } from 'express';
import { asyncRoute } from '@core/middleware/error.middleware.js';
import { auditAccess } from '@core/audit/audit.middleware.js';
import LabOrdersContainer from '../containers/lab-orders.container.js';

/**
 * Everything the laboratory has released during one visit.
 *
 * This is the question a clinician opening an encounter actually asks, and the
 * reason his.lab_orders.visit_number exists. It is answered entirely from our
 * own database: the visit never travels to OpenELIS, and a returning result is
 * matched to its order first, which is what makes the visit known again.
 *
 * Audited as a read of patient data, because that is what it is — a visit
 * number identifies one patient's encounter, and the results returned are
 * clinical.
 */
const router = Router();
const controller = LabOrdersContainer.labOrderController;

router.get(
  '/:visitNumber/results',
  auditAccess('visit.results.read', 'R', (req) =>
    req.params.visitNumber ? `Encounter/${req.params.visitNumber}` : undefined),
  asyncRoute(controller.listResultsForVisit),
);

export default router;
