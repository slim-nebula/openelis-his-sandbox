import type { Request, Response } from 'express';
import {
  parseCreateLabOrder,
  parseRecordCollection,
  parseReleasedResult,
} from '../validators/lab-order.validator.js';
import type { LabOrderService } from '../services/lab-order.service.js';
import type { IReleasedResultMessage } from '../types/lab-order.types.js';

export class LabOrderController {
  constructor(private readonly orders: LabOrderService) {}

  create = async (req: Request, res: Response): Promise<void> => {
    // The ordering clinician is read here and nowhere else. This is the only
    // point in the request that knows who is calling for certain — the token
    // has been verified and its session checked — so it is the only honest
    // place to establish it. Everything downstream takes it as given.
    //
    // usr_full_name is what a laboratory report prints; usr_id is what
    // identifies the person. The name can be spelled three ways, the id cannot.
    const clinician = {
      id: req.user!.usr_id,
      name: req.user!.usr_full_name || req.user!.usr_name,
    };

    // Nothing here talks to the broker. The order row, its audit row and the
    // lab.order.created event commit together; the relay puts the event on
    // Kafka. A broker outage therefore cannot fail an order or leave one
    // undispatched.
    const order = await this.orders.create(
      parseCreateLabOrder(req.body), clinician, req.correlationId,
    );
    res.status(201).location(`/lab-orders/${order.orderId}`).json(order);
  };

  /**
   * The nurse's action: the specimen has been drawn.
   *
   * This is what dispatches an inpatient order. Until it happens the laboratory
   * has heard nothing, because there was nothing yet for it to act on — the
   * order and the collection time leave together, in one transaction.
   */
  recordCollection = async (req: Request, res: Response): Promise<void> => {
    const order = await this.orders.recordCollection(
      req.params.orderNumber as string,
      parseRecordCollection(req.body),
      req.correlationId,
    );
    res.json(order);
  };

  listFacilities = async (_req: Request, res: Response): Promise<void> => {
    res.json(await this.orders.listFacilities());
  };

  getById = async (req: Request, res: Response): Promise<void> => {
    res.json(await this.orders.getWithResults(req.params.id as string));
  };

  listResultsForVisit = async (req: Request, res: Response): Promise<void> => {
    res.json(await this.orders.resultsForVisit(req.params.visitNumber as string));
  };

  internalPayload = async (req: Request, res: Response): Promise<void> => {
    const payload = await this.orders.bridgePayload(req.params.id as string);
    if (!payload) {
      res.status(404).json({ status: false, message: 'Unknown order.', data: null });
      return;
    }
    res.json(payload);
  };

  /**
   * The brief permits results to arrive over the internal API as well as over
   * Kafka, so this path has to be exactly as idempotent as the consumer.
   */
  internalResult = async (req: Request, res: Response): Promise<void> => {
    parseReleasedResult(req.body);
    const message = req.body as IReleasedResultMessage;
    const stored = await this.orders.storeResult({
      ...message,
      correlationId: message.correlationId ?? req.correlationId,
    });
    if (!stored) {
      res.status(404).json({ error: 'Unknown order number.' });
      return;
    }
    res.status(202).end();
  };
}
