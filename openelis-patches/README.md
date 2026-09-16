# Patches to OpenELIS

OpenELIS is the accredited component of this stack. Everything in this directory
modifies it, so everything in this directory needs a reason that survives being
read by a laboratory quality manager.

---

## The rules

**1. Patches are diffs against a named upstream release tag. Never anything else.**

Not an edit to a running container, not a file baked into an image by hand. A
patch lives in `<version>/NNNN-short-name.patch` and applies cleanly to a fresh
checkout of that exact tag. If it does not apply, that is information — upstream
touched the same code and the change must be re-reasoned, not forced.

**2. Every patch states what it touches and proves it stays on the integration
surface.**

| Patchable — the integration surface | Off limits — laboratory core |
|---|---|
| FHIR remote order import | results entry |
| the incoming-orders view | validation and release |
| order-entry prefill | QC and Westgard rules |
| terminology / catalogue read paths | accessioning logic, sample handling |
| | reporting, the audit trail |
| | security and authorisation |
| | database migrations (liquibase) |

A patch that touches anything in the right-hand column does not go in this
directory. It goes to upstream as an issue and waits.

**3. The stack runs stock by default.**

`.env` decides whose build runs:

```
OE_IMAGE_REPO=itechuw      # stock, unmodified upstream — the default
OE_VERSION=3.2.2.0
```

Switching to `OE_IMAGE_REPO=his-sandbox` runs the patched build. That is a
deliberate two-line edit, and `docker ps` always shows which one is live. The
integration must remain demonstrable against unmodified upstream, because that
is the first thing an implementer needs to know.

**4. A patch is a liability, not an asset.**

Every one costs a re-apply and a full re-validation at every upgrade, for ever.
The bar is not "this would be better" — it is "the integration is unsafe without
it, and nothing outside OpenELIS can fix it." Two candidates were rejected under
this rule; see *Rejected* below.

---

## Why patching at all is legitimate

The earlier constraint here was "never modify OpenELIS, it would break
accreditation". That framing was wrong.

**ISO 15189:2022 clause 7.6.3(a)** requires that *any* change — including
configuration — be authorized, documented and validated before use. It does not
require unmodified software. A documented, validated patch is legitimate; an
undocumented configuration tweak is not. What the standard actually costs you is
**ownership of validation for ever**, which is why rule 4 exists.

OpenELIS is MPL-2.0, which is file-level weak copyleft: modified files must stay
under the MPL and their source made available. Patches here are plain diffs, so
that obligation is met by this directory existing.

---

## Applying

```sh
make openelis-patched          # checkout the tag, apply, build, tag locally
```

then set `OE_IMAGE_REPO=his-sandbox` in `.env` and `make up`.

The build produces `his-sandbox/openelis-global-2:<version>` from
`scripts/build-openelis.sh`, which runs `docker build` against **upstream's own
`Dockerfile`, unmodified** — the patched image is built the way upstream builds
theirs. (Upstream's `build.sh` is not involved: it packages a standalone
installer from a git *branch*, which is not what we want. The Docker image has
always come from the Dockerfile.)

**Only the webapp image is patched.** `openelis-global-2-fhir`, `-frontend`,
`-proxy` and the database image are pinned to `itechuw` in
`compose/openelis.yml` regardless of `OE_IMAGE_REPO`, because no patch touches
them and this script does not build them. Three services do take the patched
image — `oe-peer-cert`, `oe-trust-bridge` and the webapp — because the first two
use it purely as a `keytool` toolbox.

## Re-applying after an upgrade

1. `git clone --branch <new-tag>` a fresh checkout, **and initialise the
   `dataexport` submodule**. It is a submodule, and the Dockerfile builds it
   before anything else; a plain clone leaves the directory empty and the build
   dies with `no POM in /build/dataexport/dataexport-core`.
   `scripts/build-openelis.sh` does this and checks the result.
2. `git apply` each patch in numeric order.
3. **A conflict is the point of this process.** It means upstream changed the
   code the patch depends on. Read their change. The patch may be unnecessary
   (fixed upstream — delete it and say so here), or may need rewriting against
   the new shape. Never force it.
4. **Prove the change reached the compiled artefact**, rather than trusting that
   `git apply` reported success. A patch can apply to a file that is no longer
   compiled into the WAR, or to a class upstream has since moved — and both
   failures are silent. Read the constant pool of the class you patched:

   ```sh
   CID=$(docker create --platform linux/amd64 his-sandbox/openelis-global-2:<version>)
   docker cp "$CID:/usr/local/tomcat/webapps/OpenELIS-Global.war" ./oe.war
   docker rm -f "$CID"
   unzip -o -q oe.war "WEB-INF/classes/.../FhirApiWorkFlowServiceImpl.class" -d warx
   python3 -c "
   b=open('warx/WEB-INF/classes/.../FhirApiWorkFlowServiceImpl.class','rb').read()
   for n in [b'scheduling/annotation/Async', b'fixedDelayString', b'fixedRateString']:
       print(n.decode(), b.count(n))"
   ```

   For patch 0001 the expected result is `Async 0`, `fixedDelayString 1`,
   `fixedRateString 0`. A non-zero `Async` count means the annotation is still
   interned — the patch did not take, whatever `git apply` said.

   (Use `python3` on the host: macOS `strings` misreads a `.class` file as a
   Mach-O binary and reports nothing.)
5. Re-run the full suite against the patched build.
6. Update the verification table of the patch entry below — every row, not just
   the last one.

---

## Patches

**None. This repository carries no patches against OpenELIS, and that is the
intended steady state.**

One was carried between 25 August and 16 September 2026 and has been retired.
The reasoning is kept below, because the decision to *stop* carrying a patch is
worth as much as the decision to write one, and because the evidence may matter
again at a future release.

### Retired — 0001, serialise the remote Task poll

Recover it with `git show 033cbca -- openelis-patches/3.2.2.0/`.

**What it did.** In `FhirApiWorkFlowServiceImpl`, changed
`@Scheduled(fixedRateString=…)` to `fixedDelayString` and removed `@Async` from
`processWorkflow`, so OpenELIS's remote Task polls could not overlap.

**The problem it addressed was real.** On 24 August 2026, on the first clean
rebuild of the whole stack, OpenELIS imported the same Task twice within two
seconds, 409'd on a client-assigned FHIR id, never acknowledged the Task, and
re-polled it for twenty-six minutes — one pass of which created a duplicate
`clinlims.patient` row. The obvious confound was checked and eliminated: the
import lines fell into four series each repeating every 60 seconds where
30000 ms configures two, so the over-firing was inside a single instance, not
two replicas.

**Why it was retired anyway.** Four reasons, in order of weight:

1. **The lease already covers it, and predates it.**
   `db/bridge/005_delivery_lease.sql` landed in `666d952` — *the same commit
   that recorded the incident*, a full day before the patch existed. Measured on
   2026-09-16: ten simultaneous polls issuing exactly the search OpenELIS
   issues, and **one** received the Task. The control — the same ten against
   `?_id=`, which deliberately takes no lease — returned it to **all ten**. The
   lease is what has been carrying this, not the patch.

2. **The window the patch closes is not close to being reached.** Its argument
   was that a lease can expire mid-import. Measured import duration on real
   orders: **1.1 to 5.4 seconds**, against a 90-second lease. An import would
   have to run seventeen times slower than the worst observed — and the remedy
   for that is `BRIDGE_TASK_LEASE_SECONDS=300` in our own `.env`, which is a
   config change we own rather than a modification to the accredited component.

3. **It had no evidence of its own.** No second observation, no reproduction,
   and its own text conceded it: *"It does not prove the race is closed, because
   the suite never provokes two overlapping poll executions."* Its validation
   record was taken at 195 checks against a suite that had grown to 355, and it
   was never re-validated after the bridge was rewritten in Node.

4. **It was never actually in use.** `OE_IMAGE_REPO` has shipped `itechuw`
   throughout. Every suite result this project has ever published — including
   355 green — was produced against **stock** OpenELIS.

**What remains uncovered, stated honestly.** The lease keys on one Task. Two
overlapping polls holding *different* Tasks for the *same new patient* would
still race inside OpenELIS's patient create. It is narrow — a poll claims its
whole batch in one statement, so the second usually gets nothing — and it has
not been seen in three weeks and 526 accepted Tasks. If it ever is, that is the
observation that would justify bringing the patch back, and it should be
recorded here when it happens.

**What was kept.** The upstream report,
[`docs/upstream-issues/01-task-poll-not-idempotent.md`](../docs/upstream-issues/01-task-poll-not-idempotent.md),
is unchanged and still worth filing: a Task whose import throws is never
acknowledged and is re-polled for ever, and **neither the lease nor the patch
fixes that**. Only upstream acknowledging the Task can. The machinery —
`make openelis-patched` and `scripts/build-openelis.sh` — is also kept, ready
for a patch that earns its place.

## Rejected — deliberately not patched

**The `crosstest` / `crosspanel` key mismatch.** `Index.jsx:221-222` reads
`order.crosstest`; the server emits `<crosstests>`. The ambiguous-test chooser is
fed an empty array and never renders. Real, and confirmed present in 3.2.2.0 —
but we never reach it, because the catalogue offers one row per (test, specimen)
and the order carries a specimen, which 3.2.2.0 resolves before any chooser is
needed. Patching it would buy us nothing and cost a re-apply for ever. Report it
upstream; do not carry it.

**The empty requester.** `Task.owner` is the routing address OpenELIS filters on,
and `LabOrderSearchProvider` reads the requester from that same field first, so
the fallback to `ServiceRequest.requester` is unreachable. Also real, also present
in 3.2.2.0 — and no longer applicable: the HIS does not send an ordering
clinician at all, because the laboratory does not act on it. A patch for a field
we do not populate is pure liability.

Both are worth filing upstream. Neither is worth carrying.
