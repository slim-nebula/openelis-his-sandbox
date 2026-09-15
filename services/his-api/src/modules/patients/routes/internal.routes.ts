import { Router } from 'express';
import { asyncRoute } from '@core/middleware/error.middleware.js';
import PatientsContainer from '../containers/patients.container.js';

/**
 * Bridge-facing. Not routed by Kong: the bridge reaches this service directly
 * over the sandbox network, so integration traffic never transits the public
 * edge.
 */
const router = Router();
const patients = PatientsContainer.patientService;

router.get(
  '/:id',
  asyncRoute(async (req, res) => {
    res.json(await patients.getById(req.params.id as string));
  }),
);

export default router;
