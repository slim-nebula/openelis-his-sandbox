# An electronic order cannot be cancelled over FHIR: `OrderType` is hardcoded to `REQUEST`

## Summary

OpenELIS has a complete cancellation path for electronic orders — an interpreter
result, a worker branch, a persister method, a status, and duplicate-detection
that understands the cancelled state. All of it is reachable from HL7 and none of
it from FHIR, because the FHIR interpreter assigns the order type
unconditionally.

A system integrating over the remote-Task path can create orders and cannot
withdraw them. There is no message it can send, and no error telling it so — a
cancellation simply arrives as a second order.

## Where

`TaskInterpreterImpl.interpret()`, tag `3.2.2.0` (`aa00894`):

```java
// gnr: make electronic_order.external_id longer
if (labOrderNumber != null && labOrderNumber.length() > 60) {
    labOrderNumber = labOrderNumber.substring(labOrderNumber.length() - 60);
}
orderType = OrderType.REQUEST;
```
`:147`

That is the only assignment to `orderType` on the FHIR path. Nothing in the
`Task` or the `ServiceRequest` is consulted — not `Task.status`, not
`Task.intent`, not `ServiceRequest.status`, all of which carry a cancellation in
FHIR R4 (`Task.status = cancelled`, `ServiceRequest.status = revoked`).

## The machinery it makes unreachable

`TaskWorker.handleOrderRequest()` already branches on it, and correctly:

```java
case ORDER_FOUND_QUEUED:
    if (orderType == OrderType.CANCEL) {
        cancelOrder(referringOrderNumber);        // <- unreachable from FHIR
        return TaskResult.OK;
    } else {
        return TaskResult.DUPLICATE_ORDER;
    }
case ORDER_FOUND_INPROGRESS:
    return orderType == OrderType.CANCEL
        ? TaskResult.NON_CANCELABLE_ORDER        // <- unreachable
        : TaskResult.DUPLICATE_ORDER;
```
`TaskWorker.java:111-126`

Behind it, all working and all tested by the HL7 path:

- `DBOrderPersister.cancelOrder()` — sets `ExternalOrderStatus.Cancelled` (`:401`)
- `IStatusService` maps that status (`StatusService.java:433`)
- `DBOrderExistanceChecker` returns `ORDER_FOUND_CANCELED`, and `TaskWorker`
  correctly allows a *new* order to be entered against a cancelled one (`:136`)
- `LabOrderSearchProvider` renders `electronic.order.message.canceled` (`:288`)

So the state, the transition, the guard against cancelling in-progress work, and
the display are all present. Only the trigger is missing.

## Impact

An integrating HIS cannot withdraw an order it has already sent. In practice:

- **Duplicate laboratory work.** A withdrawn order stays `Entered` in Incoming
  Orders indefinitely. If the HIS re-sends a corrected version — a different
  test, a corrected specimen, a re-created order after a billing failure — the
  laboratory sees two live orders for one patient and no indication which is
  current. A technician may draw and run both.
- **Silent.** `TaskResult.NON_CANCELABLE_ORDER` and the `CANCEL` branches never
  execute, so nothing is logged and no status is returned. The integrating
  system has no way to discover the capability is absent short of reading this
  source.
- **The withdrawal becomes a manual step inside the laboratory**, performed by
  someone who has to be told out-of-band which order to void.

Severity is moderate rather than high because the window is bounded: an HIS that
withholds an order until it is final — clinically approved, payment cleared —
rarely needs to withdraw one. But that is a property of the sending system, not
a guarantee of the protocol, and a patient who dies or is discharged between
order and draw is not an unusual event.

## Suggested direction

Derive the order type from the resources rather than assuming it. The natural
mapping already exists in FHIR R4:

```java
orderType = (task.getStatus() == Task.TaskStatus.CANCELLED
          || serviceRequest.getStatus() == ServiceRequest.ServiceRequestStatus.REVOKED)
        ? OrderType.CANCEL
        : OrderType.REQUEST;
```

Nothing downstream needs to change — `TaskWorker` and `DBOrderPersister` already
handle both branches.

Two smaller points worth considering alongside it:

- The remote poll filters `Task?status=requested&owner=…`, so a Task the sender
  moved to `cancelled` would no longer be returned by that query. A cancellation
  therefore needs either a second poll for `status=cancelled`, or acceptance of
  the cancellation on the existing `PUT /Task/{id}` path.
- `TaskResult.NON_CANCELABLE_ORDER` should reach the sender rather than only the
  log, so an HIS can tell "cancelled" from "too late, work has started" — those
  need different handling on the clinical side.

## Environment

- OpenELIS Global 2 v3.2.2.0, official image `itechuw/openelis-global-2:3.2.2.0`
- Remote Task poll integration path (`org.openelisglobal.remote.source.uri`)
- Line numbers are from tag `3.2.2.0` (`aa00894`)
