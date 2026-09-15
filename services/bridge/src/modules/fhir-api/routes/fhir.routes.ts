import { Router } from 'express';
import FhirContainer from '../containers/fhir.container.js';

const controller = FhirContainer.controller;

/**
 * The FHIR R4 surface, mounted at /fhir in app.ts behind the peer guard.
 *
 * ORDER MATTERS. `/metadata` is declared before `/:type` because Express
 * matches in declaration order and `metadata` is a perfectly good value for
 * `:type` — reversed, OpenELIS's very first request would be answered with an
 * empty searchset for a resource type called "metadata", and the integration
 * would fail its version check with nothing obviously wrong in the log.
 *
 * The bare `POST /` is the transaction bundle the periodic export pushes.
 */
export const fhirRouter = Router();

fhirRouter.get('/metadata', controller.metadata);

fhirRouter.post('/', controller.transaction);

fhirRouter.get('/:type', controller.search);
fhirRouter.get('/:type/:id', controller.read);
fhirRouter.put('/:type/:id', controller.update);
fhirRouter.post('/:type', controller.create);

export default fhirRouter;
