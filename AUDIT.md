# Audit report and improvement plan

*Written 2026-09-09 by an independent review session (Fable) for the implementing
session (Opus). The entire estate was re-read from scratch — every bridge source
file, the his-api modules, both database schemas, the compose files, Kong, the
mTLS material, `docs/security.md` and all eleven test suites — and measured
against the standard reference architecture for HIS–LIS integration (FHIR
contract, LOINC mapping, identity ownership, explicit state machine, corrections,
boundary security, retries and idempotency).*

---

## Part 1 — Findings

### 1.1 Verdict

**The integration is architected the right way and executed above MVP standard.
Do not re-litigate the load-bearing decisions.** The reference pattern — a
dedicated integration service between the HIS and the LIS, owning the mapping,
the state machine, idempotency and the failed-message queue — is exactly what the
bridge is, and the network layout makes bypassing it impossible rather than
forbidden.

Every item on the standard checklist passes:

| Checklist item | Where it is satisfied |
|---|---|
| FHIR as the canonical contract, adapter isolates the LIS | `services/Bridge/` — one container, sole occupant of `oe-integration-net` alongside the webapp |
| No coupling to LIS tables | Network membership + separate databases; no shared schema |
| LOINC-based mapping, controlled | Discovered from OpenELIS, keyed (LOINC, specimen); `CatalogueSync.cs`, shrink guard, one-transaction swap |
| Identity ownership decided | HIS owns the patient (one identifier crosses); lab owns the accession; both shown side by side |
| Explicit state machine | `CREATED → AWAITING_COLLECTION → SENT_TO_LIS → ACCEPTED/REJECTED_BY_LIS → RESULT_AVAILABLE` + monotonic `lab_progress` |
| Corrections supported | `final/amended/corrected/entered-in-error` all forwarded; claim keyed on (report, version); previous value surfaced |
| Boundary secured | mTLS pinned peer, JWT + revocation, internal service key, fail-closed admin tokens, fixed-time compares |
| Retry / idempotency / audit / DLQ | Transactional outbox, claim tables both sides, poison-message DLQs both directions, `lab_order_events` |
| Version-specific validation | Pinned 3.2.2.0, behaviour read from deployed classes, six upstream defect reports |

Roughly 260 end-to-end assertions across eleven suites, green at the last full
sweep.

### 1.2 What must not change

These were examined and confirmed correct. Any future change that touches them
needs a stronger argument than "cleaner":

- **The pull model.** OpenELIS polls; the bridge holds. Pushing would fight the
  LIS's design.
- **Zero patches to the LIS.** The accreditation argument stands. Workarounds
  live in the bridge, documented and re-appliable (`openelis-patches/README.md`).
- **The outbox.** A broker outage delays an order; it can never lose one or leave
  one half-created.
- **The asymmetric refusal logic** in `Messaging.cs` (`ProcessOrderAsync`):
  refuse ambiguous orders (LOINC known, specimen unresolvable), pass unknown
  LOINCs through so the laboratory's rejection remains the drift signal.
- **Token-only attribution.** The ordering clinician is established from the
  verified token at creation and only ever read afterwards. Any field letting a
  caller *name* a clinician is a defect. (Memory: `his-ordering-clinician-rule`.)
- **`Task.owner` typed as Organization** and the ServiceRequest id being the
  order number — both are load-bearing against upstream behaviour (defects 02 and
  the Incoming Orders 404).

### 1.3 Defects found by this audit

Only two, both small:

1. **Stale comment** — `gateway/kong/kong.yml` (catalogue-refresh route, ~lines
   83–90) still says the endpoint "is unauthenticated, like everything else in
   this sandbox". It has been behind `HIS_ADMIN_TOKEN` (fail-closed,
   `admin.middleware.ts`) for some time. The comment now instructs readers to add
   a control that already exists.
2. **Panel results flatten to one value** — see work item A. Not a bug for the
   current single-analyte menu; a data-loss bug the day a panel is offered.

Everything else on the improvement list below was already self-identified in
`docs/security.md` §9 — the audit confirms that list is accurate and complete
except for the two items above.

---

## Part 2 — Implementation plan

Standing constraints for every work item:

- The 8 GiB build host: **stop the stack before any full image build**; amd64
  builds run emulated (memory: `build-host-constraints`).
- OpenELIS stays stock. No new patches unless unavoidable, and then only via the
  documented patch strategy.
- Every behavioural change gets test coverage in the existing suite style, and
  new checks get mutation-tested once (inject the bug, watch the check go red).
- Docs are part of done: `integration-guide.md` / `integration-field-map.md` for
  anything the user's developers will consume; `his-findings.md` for anything
  about the real HIS; `security.md` §9 updated when an item there is closed.
- The estate is Latin-name only; do not resurrect the charset work.

### Phase 0 — hygiene (minutes, zero risk)

**Item H1: fix the Kong comment.** Rewrite the `catalogue-refresh` route comment
in `gateway/kong/kong.yml` to say the endpoint is behind `HIS_ADMIN_TOKEN`,
fail-closed, enforced in his-api (`requireAdminToken`) — Kong routes it, his-api
guards it. No behaviour change, no test needed.

### Phase A — panel / multi-observation results (the priority)

**Problem.** `ResultCorrelator.ForwardAsync` calls `FirstObservationAsync` and
`Flatten` (ResultCorrelator.cs), so a `DiagnosticReport` carrying several
`Observation`s — a CBC, an electrolyte panel — forwards only its first analyte.
The HIS would show one number for a five-component panel with nothing indicating
loss.

**Design.**

1. **Message contract** (`lab.result.released`): add an `observations` array —
   each element `{ code, name, value, unit, referenceRange, interpretation,
   interpretationCode }`, in report order. **Keep every existing flat field**,
   populated from the first observation exactly as today, so current consumers
   and every existing suite assertion keep working. For a retraction the array is
   empty, matching the existing null-out rule (the retraction is the whole
   message).
2. **Bridge** (`ResultCorrelator.cs`): replace `FirstObservationAsync` with a
   method returning all resolvable Observations in `report.Result` order;
   `Flatten` becomes per-observation; the flat fields take element zero. The
   observation's own `code.coding` (LOINC preferred, else first) is the
   component key. Missing Observations (referenced but not yet mirrored) follow
   the existing patience rule: if *any* referenced Observation is unresolvable
   and the report is younger than `CorrelationRetryMinutes`, leave the report for
   the next sweep rather than forward a partial panel. After the window, forward
   what resolved and log what did not — a late partial result beats silence.
3. **HIS schema** — new migration `db/his/016_result_components.sql`: a child
   table `his.lab_result_components (component_id, result_id → lab_results_summary,
   analyte_code, analyte_name, result_value, result_unit, reference_range,
   interpretation, interpretation_code, position int)`, unique on
   `(result_id, analyte_code, position)`. **Do not** widen the unique key on
   `lab_results_summary` — the report-level upsert on `openelis_result_ref` is
   load-bearing for correction idempotency. On upsert of a result, delete and
   re-insert its components in the same transaction (a correction replaces the
   component set).
4. **his-api** (`lab-order.model.ts`): `upsertResult` writes components;
   `RESULT_SELECT` gains a lateral/aggregated join returning components as JSON;
   `IResultSummary` gains `components: IResultComponent[]` (empty for
   single-analyte results — the frontend shows the flat value as today when
   `components.length <= 1`).
5. **Frontend**: render components as rows under the result when more than one.
   Keep the report-level status/interpretation on the parent row.

**Testing** (`scripts/test-results-panel.sh`, or a section in
`test-result-return.sh`): push a synthetic `DiagnosticReport` with three
`Observation`s through `/fhir` the way the existing result suites do; assert the
Kafka message carries three array elements *and* the legacy flat fields equal
element zero; assert three component rows in `his.lab_result_components`; replay
the same push and assert no duplicates; push an `amended` version with a changed
component and assert replacement, not accumulation; push a retraction and assert
components are cleared. Mutation-test by reverting the correlator to
first-observation and watching the suite fail.

**Docs**: new section in `integration-field-map.md` (message shape, ordering,
the partial-panel rule); a paragraph in `integration-guide.md` telling the
developers to read `observations` and treat the flat fields as a compatibility
view.

### Phase B — monitoring and alerting

**Problem.** `/metrics` is exposed everywhere but nothing scrapes it, and the
dangerous failure modes are quiet: an undelivered order, a stopped poll, an
ageing catalogue, growing dead letters.

**Design.**

1. **New gauges on the bridge** (they do not exist yet; the alerts need them):
   - `bridge_tasks_requested_age_seconds` (oldest Task still `requested`)
   - `bridge_dead_letters_total` (row count)
   - `bridge_catalogue_age_seconds` (now − max synced_at)
   - `bridge_last_poll_age_seconds` (now − last `GET /fhir/Task` with the poll
     shape; stamp the time in `SearchTasksAsync`)
   Cheap queries; refresh on a timer (30 s) rather than per scrape.
2. **One Prometheus container** in `compose/platform.yml`, minimal footprint
   (`--storage.tsdb.retention.time=2d`, memory limit ~256 MiB — the 8 GiB host
   is the constraint). Scrape bridge, his-api, Kong. **Skip Alertmanager**: use
   Prometheus alert *rules* and surface firing alerts via `make alerts`
   (`curl /api/v1/alerts`). A pager is the real HIS's concern; the sandbox's job
   is to demonstrate the rules and name them for the developers.
3. **Four rules**, mirroring `security.md` §9: order undelivered > 15 min;
   dead letters increased in the last hour; catalogue older than 45 days
   (warning only); no OpenELIS poll for > 5 min while the stack is up.

**Testing**: extend `test-smoke.sh` — Prometheus healthy, all three targets
`up == 1`. In `test-negative.sh`, stop the poll path (pause `openelis-webapp`),
wait, assert the `NoRecentPoll` alert reaches `firing`, unpause, assert it
clears. Mind memory: this suite step must not run while a build is in flight.

**Docs**: `runbook.md` gains an "alerts" section — what each rule means and the
first response to each; `security.md` §9 marks the monitoring paragraph closed
for the sandbox scope.

### Phase C — patient demographic freeze (investigate, then document)

**Problem.** Defect 05 proved OpenELIS never refreshes a Practitioner's name
after first import. The Patient path is suspect for the same freeze
(`getPatientWithSameServiceIdentifier` is the analogous lookup), and nothing
currently proves it either way. A patient whose name was corrected in the HIS
after their first order may keep the wrong name on laboratory reports forever.

**Plan.** Empirical test first: order for a patient, let OpenELIS import it,
correct the patient's name via the HIS API, order again, then read OpenELIS's
patient record (its own DB or the accessioning wizard endpoint, same technique
as `test-requester.sh` §3).
- If it refreshes: one paragraph in `integration-field-map.md` saying so, with
  the evidence, and a regression check in `test-requester.sh` style.
- If it freezes: `docs/upstream-issues/07-patient-name-never-refreshed.md`
  (same shape as 05), a workaround note for the developers (demographic
  corrections must reach the laboratory out of band today), and the check
  asserts the *documented* behaviour so a future OpenELIS release that fixes it
  turns the check red and tells us.

### Phase D — reconciliation report

**Problem.** Nothing produces a "sent vs accepted vs resulted" tally; a slow
leak (one order a day quietly dead-lettered) is invisible until someone counts
by hand. All the data already exists in `bridge.order_tracking`,
`bridge.forwarded_results` and `bridge.dead_letters`.

**Plan.** `GET /ops/reconciliation?days=7` on the bridge (behind
`OpsAccessFilter`): per day — orders taken on, accepted, rejected, still
`requested` (with age buckets: <1 h, <24 h, older), results forwarded, dead
letters. Pure read, one query with filters. `make reconcile` prints it in the
style of `make prune`. A check in `test-negative.sh`: place an order, assert it
appears in the outstanding bucket, complete it, assert it moves. Document in
`runbook.md` as the daily glance.

### Phase E — optional, when the above is green

- **E1: unit tests.** An xunit project for the pure functions
  (`OrderMapper.SplitName`, `DeterministicGuid` against RFC 4122 v5 vectors,
  `MapPriority`, `BuildSpecimenCodings`, the new per-observation `Flatten`) and
  vitest for `lab-order.validator.ts`. Run in-container; never alongside a full
  image build on this host.
- **E2: ATNA groundwork.** Emit security audit events (who read which patient,
  from where, outcome) in RFC 3881-shaped JSON to a `security.audit` topic from
  his-api — the identity is already on `req.user`, the transport already exists.
  Schema and destination only; the Audit Record Repository is the real HIS's.

### Explicitly out of scope for Opus (belongs to the user's real HIS team)

Record these in `his-findings.md` if not already there; do not implement them in
the sandbox:

- IAM: sign RS256, add `aud`; fix `jwt.decode` → `jwt.verify` in
  `HIS-org-setup-service` and `file-upload-service`; remove the hardcoded
  fallback secret in `file-upload-service`.
- TLS on the internal hops; real PKI with rotation; `OE_REST_ACCEPT_ANY_CERT=false`.
- Three Kafka brokers (parameters already exist).
- Business-unit scoping (needs Casbin, which is theirs).
- Kong admin port, CORS origins, rate limiting — production gateway config.

### Sequencing and definition of done

Order: **H1 → A → B → C → D → E**. A is the only one with schema and contract
changes; land it alone and run the *entire* suite sweep before starting B.

Done means, for each phase: suites green including the new checks, new checks
mutation-tested, docs updated, `security.md` §9 amended where an item closed,
and one commit per phase with a message saying what changed and why.
