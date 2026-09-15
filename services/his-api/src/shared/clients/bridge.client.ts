import { bridgeClient } from './base-api.client.js';

export interface DiscoveredTest {
  loinc: string;
  name: string;
  specimenName: string;
  resultUnit: string | null;
}

interface CatalogueResponse {
  syncedAt: string | null;
  count: number;
  tests: DiscoveredTest[];
}

/**
 * Reads the test menu the bridge discovered in OpenELIS.
 *
 * Read-only, and unauthenticated on purpose: it is an internal service-to-
 * service read of non-sensitive reference data, governed by network membership
 * like /internal/* is. Only the endpoints that CHANGE the menu carry a token.
 */
export const fetchDiscoveredCatalogue = async (): Promise<DiscoveredTest[]> => {
  const { data } = await bridgeClient.get<CatalogueResponse>('/catalogue');
  return data.tests ?? [];
};
