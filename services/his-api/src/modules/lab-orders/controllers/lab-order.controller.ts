import type { Request, Response } from 'express';
import { parseCreateLabOrder, parseReleasedResult } from '../validators/lab-order.validator.js';
import type { LabOrderService } from '../services/lab-order.service.js';
import type { IReleasedResultMessage } from '../types/lab-order.types.js';

export class LabOrderController {
  constructor(private readonly orders: LabOrderService) {}

  create = async (req: Request, res: Response): Promise<void> => {
    // Nothing here talks to the broker. The order row, its audit row and the
    // lab.order.created event commit together; the relay puts the event on
    // Kafka. A broker outage therefore cannot fail an order or leave one
    // undispatched.
    const order = await this.orders.create(parseCreateLabOrder(req.body), req.correlationId);
    res.status(201).location(`/lab-orders/${order.orderId}`).json(order);
  };

  getById = async (req: Request, res: Response): Promise<void> => {
    res.json(await this.orders.getWithResults(req.params.id as string));
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
