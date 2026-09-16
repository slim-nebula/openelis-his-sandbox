import { FhirModel } from '@modules/fhir-api/models/fhir.model.js';
import { OrderTrackingModel } from '@modules/orders/models/order-tracking.model.js';
import { DeadLetterModel } from '@shared/models/dead-letter.model.js';
import { EventClaimModel } from '@shared/models/event-claim.model.js';
import { ForwardedResultModel } from '../models/forwarded.model.js';
import { ReceivedModel } from '../models/received.model.js';
import { ProgressTracker } from '../progress.tracker.js';
import { ResultCorrelator } from '../result.correlator.js';

/**
 * The two background workers that walk the inbound mirror.
 *
 * They share the ReceivedModel instance deliberately: both sweep the same table
 * on overlapping timers, and one pool-backed model is the whole point of having
 * a model at all.
 */
export class ResultsContainer {
  private static _received: ReceivedModel;
  private static _correlator: ResultCorrelator;
  private static _progress: ProgressTracker;

  static get received(): ReceivedModel {
    if (!this._received) this._received = new ReceivedModel();
    return this._received;
  }

  static get correlator(): ResultCorrelator {
    if (!this._correlator) {
      this._correlator = new ResultCorrelator(
        this.received,
        new ForwardedResultModel(),
        new OrderTrackingModel(),
        new EventClaimModel(),
        new DeadLetterModel(),
        new FhirModel(),
      );
    }
    return this._correlator;
  }

  static get progress(): ProgressTracker {
    if (!this._progress) {
      this._progress = new ProgressTracker(this.received, new OrderTrackingModel(), new EventClaimModel());
    }
    return this._progress;
  }
}

export default ResultsContainer;
