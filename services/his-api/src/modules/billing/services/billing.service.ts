import type {
  BillingMapModel,
  IBillingMapping,
  IOrphanedMapping,
  IUnmappedTest,
} from '../models/billing-map.model.js';

/**
 * Does the billing map still describe the laboratory's menu?
 *
 * The map is deployment configuration, and the menu it maps is synced from
 * OpenELIS, so the two drift on their own: the laboratory enables a test and
 * nobody prices it, or withdraws one and its charge item is left behind. Both
 * are silent. A doctor can order an unmapped test, the laboratory will run it,
 * and the hospital simply never bills for it — no error, no alert, nothing to
 * look at until somebody reconciles revenue months later.
 *
 * This is why the check matters more than the table.
 */
export interface IBillingReconciliation {
  /** Active tests on the menu. */
  orderable: number;
  /** …of which carry an active mapping. */
  mapped: number;
  /** Orderable and unmapped. Ordering one of these bills nobody. */
  unmapped: IUnmappedTest[];
  /** Mapped, but the test or the mapping is withdrawn. */
  orphaned: IOrphanedMapping[];
  /** One charge item covering several tests — a panel, or a copy-paste error. */
  shared: { chargeItemRef: string; tests: string[] }[];
  /** Mapped tests with no claim code. Legitimate for cash-only work. */
  withoutClaimCode: number;
  /** false when anything is orderable-but-unmapped. */
  complete: boolean;
}

export class BillingService {
  constructor(private readonly model: BillingMapModel) {}

  list(): Promise<IBillingMapping[]> {
    return this.model.list();
  }

  resolve(loincCode: string, specimenType: string): Promise<IBillingMapping | null> {
    return this.model.resolve(loincCode, specimenType);
  }

  async reconcile(): Promise<IBillingReconciliation> {
    const [mappings, unmapped, orphaned, shared] = await Promise.all([
      this.model.list(),
      this.model.unmapped(),
      this.model.orphaned(),
      this.model.sharedChargeItems(),
    ]);

    const active = mappings.filter((m) => m.isActive);
    return {
      orderable: active.length + unmapped.length,
      mapped: active.length,
      unmapped,
      orphaned,
      shared,
      withoutClaimCode: active.filter((m) => m.claimCode === null).length,
      // Deliberately keyed on `unmapped` alone. An orphan is untidy; an
      // unmapped orderable test is revenue nobody collects, and only one of
      // those should fail a deployment check.
      complete: unmapped.length === 0,
    };
  }
}

export default BillingService;
