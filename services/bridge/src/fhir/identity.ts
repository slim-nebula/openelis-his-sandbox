import { createHash } from 'node:crypto';

/**
 * Name-based UUIDs (RFC 4122 version 5, SHA-1) so that reprocessing the same
 * order produces the same resource ids and OpenELIS sees an update rather than
 * a duplicate.
 *
 * THIS IS THE HIGHEST-CONSEQUENCE FUNCTION IN THE SERVICE.
 *
 * A drifted implementation does not fail; it succeeds differently. Every
 * clinician becomes a NEW Practitioner in the laboratory's provider records,
 * permanently, one per order, and every replayed order becomes a second order.
 * Nothing errors and nothing is logged.
 *
 * The .NET original had to byte-swap twice, because .NET's Guid stores its first
 * three fields in native (little-endian) order while RFC 4122 is big-endian on
 * the wire. That swapping is an artefact of .NET's in-memory layout, NOT part of
 * the algorithm: it converts to network order, hashes, then converts back. Node
 * has no such layout, so the bytes here are already the wire bytes and no
 * swapping is correct.
 *
 * Verified in phase 0 against three independent references before anything was
 * built on it: Python's uuid.uuid5, the published python.org test vector, and a
 * real row the .NET bridge had written —
 *   task|137539b5-2690-46ea-b808-bcbc0d31352c
 *     -> 07e60d38-f066-5d30-8c6a-9d9acd56b930
 *
 * If this file is ever changed, re-run that comparison. A unit test asserting
 * one hard-coded pair would also work, and would be worth more than this
 * comment.
 */

/** The DNS namespace from RFC 4122 Appendix C, as the .NET service used. */
const DNS_NAMESPACE = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';

const namespaceBytes = Buffer.from(DNS_NAMESPACE.replace(/-/g, ''), 'hex');

export const deterministicUuid = (name: string): string => {
  const hash = createHash('sha1').update(namespaceBytes).update(Buffer.from(name, 'utf8')).digest();

  const bytes = Buffer.from(hash.subarray(0, 16));
  // Version 5 in the high nibble of octet 6, and the RFC 4122 variant in the
  // top two bits of octet 8. Everything else is hash output.
  bytes[6] = ((bytes[6] as number) & 0x0f) | 0x50;
  bytes[8] = ((bytes[8] as number) & 0x3f) | 0x80;

  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
};

/**
 * The four names the bridge derives ids from. Kept together because the STRING
 * is the contract, not just the algorithm: changing "task|" to "Task|" would
 * republish every order in the system under new ids.
 */
export const taskIdFor = (orderId: string): string => deterministicUuid(`task|${orderId}`);
export const specimenIdFor = (orderId: string): string => deterministicUuid(`specimen|${orderId}`);
export const practitionerIdFor = (hcpId: string): string => deterministicUuid(`practitioner|${hcpId}`);

/**
 * The referring site, as a Location id.
 *
 * Derived rather than taken from the HIS because OpenELIS calls
 * UUID.fromString on this id with no guard, exactly as it does for
 * Practitioner.id — a site key like "FAC-001" or "branch|5" would throw inside
 * the import and the order would never reach the laboratory.
 *
 * It is also permanent in a way the other three are not. On first import
 * OpenELIS CREATES an organization keyed on this uuid
 * (FhirApiWorkFlowServiceImpl, verified end to end against 3.2.2.0) and matches
 * every later order against it. So the site key must be something that does not
 * change when a clinic is renamed or its code edited, or the laboratory grows a
 * second organization for the same place and its report routing silently splits.
 *
 * In this sandbox the key is his.facilities.facility_code, because the fixture
 * has nothing else. In a real HIS it must be the table and the PRIMARY KEY —
 * "branch|5", "ward|12", "bunit|7" — because ids are per-table (branch 5 and
 * ward 5 are different places), and because in the estate's own schema `code`
 * carries no unique constraint and is nullable on business units. A key that
 * can collide or be absent is not a key.
 */
export const locationIdFor = (siteKey: string): string => deterministicUuid(`location|${siteKey}`);
