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

### 0001 — serialise the remote Task poll

**File:** `3.2.2.0/0001-serialise-remote-task-poll.patch`
**Touches:** `dataexchange/fhir/service/FhirApiWorkFlowServiceImpl.java` — 1 file,
1 insertion, 3 deletions.
**Surface:** FHIR remote order import. Touches no laboratory core.

**Verification status** — stated step by step, because "applies", "is in the
image" and "validated" are three different claims:

| Step | Status |
|---|---|
| Applies cleanly to tag `3.2.2.0` (`aa00894`) | **verified** — `git apply --check` against a fresh clone |
| Code it modifies is present and unchanged at that tag | **verified** — `FhirApiWorkFlowServiceImpl.java:89-96` |
| Patched image builds | **verified** — `his-sandbox/openelis-global-2:3.2.2.0`, 567 MB |
| The change is in the compiled artefact | **verified** — see the constant-pool check below |
| Patched build boots and serves | **verified** — Tomcat startup 205 s, `LoginPage` HTTP 200 |
| Offers the same test menu as stock | **verified** — sync reported `17 -> 17`, nothing withdrawn |
| Full suite against the patched image | **verified** — 195 passed, 0 failed |

Suite-for-suite against stock: smoke 53/0, auth 52/0, catalogue-test 22/0,
negative 50/0, rejection 18/0. The negative suite restarts the webapp mid-run,
so the patched image is also known to survive a restart and resume importing.

**What this does and does not prove.** It establishes that the patched build is
behaviourally identical to stock — that the patch broke nothing — which is the
ISO 15189 clause 7.6.3(a) requirement for a change to be validated before use.

It does **not** prove the race is closed, because the suite never provokes two
overlapping poll executions, and provoking one reliably would mean deliberately
slowing an import past the poll interval. The evidence for the fix itself remains
the code analysis: with `@Async` gone, `scheduleAtFixedRate`'s own guarantee that
a task never overlaps itself applies again.

Despite all of the above the stack still ships on `OE_IMAGE_REPO=itechuw`. The
integration must stay demonstrable against unmodified upstream, because that is
the first thing an implementer needs to know (rule 3).

**The defect.** `pollForRemoteTasks()` can run concurrently with itself. Two
executions import the same Task, race on patient de-duplication, and produce a
**duplicate patient record**. The losing execution aborts with an HTTP 409, which
leaves the Task unacknowledged, so it is re-polled every interval indefinitely —
observed as roughly fifty attempts over 26 minutes, none of which could succeed.

**Why it happens.** Not `fixedRate` on its own. The JDK's `scheduleAtFixedRate`
already guarantees a task never runs concurrently with itself — late, yes,
overlapping, no. `@Async` defeats that guarantee: the scheduled method hands the
work to `AsyncConfig`'s `SimpleAsyncTaskExecutor` and returns immediately, so the
scheduler believes the run finished and starts the next one while the real work
continues on an unbounded, new-thread-per-submission executor. Nothing serialises
them.

**The change.**

- Remove `@Async` from `processWorkflow`, restoring the scheduler's own
  non-overlap guarantee.
- `fixedRateString` → `fixedDelayString`, so a slow poll is followed by a normal
  interval rather than a burst of catch-up executions.
- Drop the now-unused import.

**Blast radius, checked rather than assumed.**

- `processWorkflow` has exactly one caller — the scheduled method itself. No
  other class in the codebase consumes `FhirApiWorkflowService`.
- The scheduler pool is `Executors.newScheduledThreadPool(10)`
  (`SchedulerConfig.java:80`) against ~12 `@Scheduled` methods, so making this one
  synchronous occupies one of ten threads rather than starving other jobs.
- It replaces an executor that created an **unbounded** thread per firing with
  one bounded slot, which is the safer direction under load.

**Why configuration cannot substitute.** Raising
`org.openelisglobal.remote.poll.frequency` lowers the probability of overlap and
cannot remove it: the trigger is "an execution outran the interval", which a
longer interval makes rarer, never impossible. No property serialises the job.

**What it does NOT fix.** A Task that genuinely cannot be imported is still
retried for ever with no attempt counter and no terminal state; and
`Task.status = rejected` still means either "the laboratory declined the order"
or "an internal indexing write failed", with no way for an integrating system to
tell them apart. Both need real upstream work.

**The bridge-side lease stays regardless.** `bridge.delivery_leases` withholds a
Task from the poll for `BRIDGE_TASK_LEASE_SECONDS` once delivered. It is not made
redundant by this patch, for a reason that matters more than it first appears:
the lease lives in *our* code and survives every OpenELIS upgrade untouched,
whereas this patch is lost at each upgrade until someone re-applies it. The lease
is the durable protection; the patch is the clean one. Keep both.

The lease also is not equivalent. It does not serialise the poll — it starves the
second execution of work — which leaves two narrow windows the patch closes: an
import outrunning the lease, and a Task arriving between two passes such that
both run with work in hand.

---

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
