import { Router } from 'express';
import { asyncRoute } from '@core/middleware/error.middleware.js';
import { auditAccess } from '@core/audit/audit.middleware.js';
import PatientsContainer from '../containers/patients.container.js';

const router = Router();
const controller = PatientsContainer.patientController;

// Every route here reads or writes patient data, so every route is audited.
// The entity is taken from the ROUTE, and the actor from the verified token —
// never from the body, which is what the caller claimed rather than what was
// proved.
const patient = (req: { params: Record<string, string | undefined> }) =>
  req.params.id ? `Patient/${req.params.id}` : undefined;

// Most specific first: /patients/search must not be matched by /patients/:id.
//
// A search is audited without an entity: it is a query, and which patients came
// back is not known until the handler has run. That it happened, and by whom,
// is the part worth keeping.
router.get('/search', auditAccess('patient.search', 'E'), asyncRoute(controller.search));
router.post('/', auditAccess('patient.create', 'C'), asyncRoute(controller.create));
router.get('/:id/lab-orders', auditAccess('patient.orders.read', 'R', patient), asyncRoute(controller.listOrders));
router.get('/:id/results', auditAccess('patient.results.read', 'R', patient), asyncRoute(controller.listResults));
router.get('/:id', auditAccess('patient.read', 'R', patient), asyncRoute(controller.getById));

export default router;
