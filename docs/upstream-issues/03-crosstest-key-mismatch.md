# Ambiguous-test chooser never renders: `crosstest` / `crosstests` key mismatch (and the unit test encodes the bug)

**Version:** 3.2.1.11 (`itechuw/openelis-global-2:develop`)
**Area:** `frontend/src/components/addOrder/Index.jsx`,
`org.openelisglobal.common.provider.query.LabOrderSearchProvider`

## Summary

When an imported order's test is ambiguous, the accessioner is supposed to be
offered a chooser. It never appears, because the line that populates it reads a
key the backend does not emit. The same file reads the same payload correctly a
few lines earlier.

## The mismatch

The backend emits a plural wrapper around singular children, matching its own
`<crosspanels>`/`<crosspanel>`:

```java
// LabOrderSearchProvider.addCrosstests
xml.append("<crosstests>");
for (String testName : testNameTestSampleTypeMap.keySet()) { ... }
xml.append("</crosstests>");
```

The frontend reads it two different ways:

```jsx
// the notification builder — correct, matches the payload
toArray(order.crosstests?.crosstest)

// the line that actually drives the chooser — reads a top-level singular key
setCrossTests(order.crosstest ? parseCrossList(order.crosstest) : []);
```

`order.crosstest` is never present at the top level, so the condition is always
falsy, `setCrossTests` receives `[]`, and the chooser's `crossTests.length > 0`
guard never opens.

## Why this has survived

`IndexCrossTests.test.jsx` mocks a payload containing a top-level `crosstest`
key — the shape the server does not send. The test therefore passes against the
broken reader, giving the defective path green coverage. Fixing the component
without also correcting the fixture will turn the test red.

## Impact

An ambiguous order gives the accessioner no prompt at all. Downstream, an
integrating system has no way to route around it except by refusing to offer
ambiguous tests in the first place.

## Suggested direction

Read `order.crosstests?.crosstest` at the chooser line, matching the notification
builder and the actual payload — and update the test fixture to the shape
`LabOrderSearchProvider` emits, so the coverage means something.

## Environment

- OpenELIS Global 2 v3.2.1.11, `itechuw/openelis-global-2:develop`
