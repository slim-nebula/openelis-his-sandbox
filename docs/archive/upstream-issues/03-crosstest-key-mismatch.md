# Ambiguous test/panel choosers never render: singular/plural key mismatch (and the unit test encodes the bug)

**Version:** 3.2.2.0 (tag `3.2.2.0`, commit `aa00894`)
**Area:** `frontend/src/components/addOrder/Index.jsx`,
`org.openelisglobal.common.provider.query.LabOrderSearchProvider`

## Summary

When an imported electronic order contains an ambiguous test or panel, the
accessioner is supposed to be offered a chooser to resolve it. Neither chooser
ever appears, because the two lines that populate them read keys the backend does
not emit.

## The mismatch

`LabOrderSearchProvider` emits a plural wrapper around singular children, for
both tests and panels:

```java
// LabOrderSearchProvider.java:761-767
private void addCrosstests(StringBuilder xml) {
    xml.append("<crosstests>");
    for (String testName : testNameTestSampleTypeMap.keySet()) {
        addCrosstestForTestName(xml, testName, testNameTestSampleTypeMap.get(testName));
    }
    xml.append("</crosstests>");
}
// addCrosstestForTestName then appends <crosstest> … </crosstest>  (:769-777)
```

`addCrosspanels` follows the same shape — `<crosspanels>` (`:730`) wrapping
`<crosspanel>` (`:739`).

The frontend reads a **singular key at the top level of `order`**, for both:

```jsx
// Index.jsx:221-222
setCrossTests(order.crosstest ? parseCrossList(order.crosstest) : []);
setCrossPanels(order.crosspanel ? parseCrossList(order.crosspanel) : []);
```

Neither `order.crosstest` nor `order.crosspanel` is ever present — the payload
nests them one level down, as `order.crosstests.crosstest` and
`order.crosspanels.crosspanel`. Both conditions are therefore always falsy, both
setters receive `[]`, and the render guard at `Index.jsx:823`

```jsx
{(crossTests.length > 0 || crossPanels.length > 0) && (
```

never opens.

## Why this has survived

`frontend/src/components/addOrder/IndexCrossTests.test.jsx` constructs its
fixture in the shape the **reader** expects rather than the shape the server
sends — `crosstest` sits directly on `order`:

```jsx
order: {
  patient: { guid: "guid-1145" },
  sampleTypes: "",
  crosstest: {                       // <- server emits crosstests > crosstest
    name: "COVID-19 PCR",
    crosssampletypes: { crosssampletype: [ … ] },
  },
},
```

The test consequently passes against the broken reader, giving the defective path
green coverage. **Fixing `Index.jsx` alone will turn this test red** — the fixture
has to move to the real payload shape in the same change, or the fix looks like a
regression.

## Impact

An ambiguous order gives the accessioner no prompt at all, and no error either —
the chooser is simply absent. An integrating system has no way to route around
this except by never offering an ambiguous orderable in the first place, which
requires it to model OpenELIS's test↔sample-type table on its own side.

## Suggested direction

Read `order.crosstests?.crosstest` and `order.crosspanels?.crosspanel` at
`Index.jsx:221-222`, and update the `IndexCrossTests` fixture to the shape
`LabOrderSearchProvider` actually emits so the coverage means something.

## Environment

- OpenELIS Global 2 v3.2.2.0, official image `itechuw/openelis-global-2:3.2.2.0`
- Verified by reading the source at tag `3.2.2.0` (`aa00894`); line numbers above
  are from that tag.
