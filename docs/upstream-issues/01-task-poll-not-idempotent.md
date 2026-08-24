# Remote Task poll runs concurrently with itself: duplicate patients, unbounded re-import, and storage failures reported as clinical rejection

**Version:** 3.2.1.11 (`itechuw/openelis-global-2:develop`)
**Area:** FHIR remote order import (`org.openelisglobal.dataexchange.fhir.service.FhirApiWorkFlowServiceImpl`)

## Summary

`pollForRemoteTasks()` can run concurrently with itself. When it does, two
executions import the same `Task`, race on patient de-duplication, and produce a
**duplicate patient record**. The losing execution aborts with a 409, which
leaves the Task unacknowledged, so it is re-polled every interval indefinitely.

## Reproduction

1. Configure a remote FHIR source: `org.openelisglobal.remote.poll.frequency=30000`.
2. Publish `Task` (`status=requested`, `owner=Practitioner/<uuid>`) +
   `ServiceRequest` + `Patient` for a patient OpenELIS has not seen before.
3. Ensure one import cycle takes longer than the poll interval — a slow remote,
   a loaded server, or emulated hardware all suffice.

## Observed

```
22:12:30 WARN  FhirApiWorkFlowServiceImpl.getTaskLoctionFromServer    <- pass 1
22:12:32 WARN  FhirApiWorkFlowServiceImpl.getTaskLoctionFromServer    <- pass 2, same Task
22:12:35 ERROR ResourceVersionConflictException: HTTP 409 HAPI-0550:
               HAPI-0825: client-assigned ID constraint failure
               (FhirPersistanceServiceImpl.createUpdateFhirResourcesInFhirStore:158)
22:12:35 ERROR FhirApiWorkFlowServiceImpl.beginTaskImportOrderPath:
               could not process Task with identifier : .../Task/<uuid>
```

Three consequences, in increasing severity:

1. **The Task is never acknowledged**, so it stays `status=requested` and the
   next poll finds it again. One order was re-imported every 30 s for 26 minutes
   — roughly fifty attempts, none of which could ever succeed. There is no
   attempt counter and no terminal failure state.

2. **A duplicate patient was created.** `clinlims.patient` ended with two rows
   holding the same `national_id`, name and date of birth. In a laboratory that
   is a manual merge, with results already attached.

3. **A storage failure was reported as a clinical refusal.** Once the duplicate
   existed, a later pass failed with
   `HSEARCH800024 / HSEARCH800022: Indexing failure: null ... [Patient#N]`
   from Hibernate Search's `afterTransactionCompletion` callback. OpenELIS then
   set `Task.status = rejected` while `electronic_order.status_id` remained `21`
   (Entered) rather than `24` (NonConforming). Over the integration,
   `rejected` is indistinguishable from the laboratory declining the order — so
   the ordering system told a clinician the laboratory had refused a test it had
   in fact accepted.

## Cause

```java
@Scheduled(initialDelay = 10 * 1000,
           fixedRateString = "${org.openelisglobal.remote.poll.frequency:120000}")
public void pollForRemoteTasks() { processWorkflow(ResourceType.Task); }

@Async
public void processWorkflow(ResourceType resourceType) { ... }
```

- `fixedRate` schedules the next invocation from the **start** of the previous
  one, so it does not wait for completion.
- `@Async` dispatches each firing to `AsyncConfig`'s `SimpleAsyncTaskExecutor`,
  which creates a new thread per submission with no pool bound and no mutual
  exclusion.

Nothing serialises the job, so any execution that outruns the interval is joined
by the next one.

The duplicate patient follows from a check-then-act race:
`saveRemoteTaskAsLocalTask` searches the local store for a Patient with a
matching service identifier and creates one if absent. Two overlapping
executions both run that search before either commits, both find nothing, and
both create.

## Why configuration cannot fix it

Raising `org.openelisglobal.remote.poll.frequency` lowers the probability of
overlap but cannot remove it: the trigger is "an execution outran the interval",
which a longer interval makes rarer, never impossible. There is no property that
serialises the job, caps retry attempts, or marks a Task terminally failed.

Note also that this is **not** a Quartz job — `SchedulerConfig` registers only
`sendSiteIndicators` and `sendMalariaSurviellanceReport` — so `quartz.properties`
and `misfireThreshold` have no effect on it.

## Ruled out

- Multiple webapp replicas: a single container, a single
  `remote.poll.frequency`, no clustering. The import log lines fall into four
  series each repeating every 60 s — four executions a minute where 30000 ms
  configures two — so the over-firing is inside one instance.

## Suggested direction

1. Prevent concurrent execution of the poll — `fixedDelay` instead of
   `fixedRate`, a bounded executor, or an explicit guard.
2. Give a failed import a terminal state and an attempt counter, so a Task that
   cannot be imported stops being retried for ever.
3. Distinguish an internal storage/indexing failure from a clinical rejection.
   `Task.status = rejected` currently conflates the two, and integrating systems
   have no way to tell them apart.

## Environment

- OpenELIS Global 2 v3.2.1.11, `itechuw/openelis-global-2:develop`
- HAPI FHIR JPA store co-resident, sharing the OpenELIS database
- External FHIR R4 server as the remote order source
