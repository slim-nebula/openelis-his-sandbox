import { Router } from 'express';
import { asyncRoute } from '@core/middleware/error.middleware.js';
import PatientsContainer from '../containers/patients.container.js';

const router = Router();
const controller = PatientsContainer.patientController;

// Most specific first: /patients/search must not be matched by /patients/:id.
router.get('/search', asyncRoute(controller.search));
router.post('/', asyncRoute(controller.create));
router.get('/:id/lab-orders', asyncRoute(controller.listOrders));
router.get('/:id/results', asyncRoute(controller.listResults));
router.get('/:id', asyncRoute(controller.getById));

export default router;
