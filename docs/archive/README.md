# Archive — background, not instructions

**Nothing in this folder is needed to integrate with the bridge.** If you are
wiring a real HIS to this sandbox, everything you need is in [`../`](../) — start
with [architecture.md](../architecture.md) and
[integration-guide.md](../integration-guide.md).

These four are kept because they record *how the integration got to be the shape
it is*, and because the findings in them still matter to somebody. They are
filed separately because they describe **problems** — in OpenELIS, in the HIS
codebase, in an earlier version of this repository — and reading a list of
problems alongside the build instructions makes it hard to tell which is which.

| | What it is | Who it is for |
|---|---|---|
| [his-findings.md](his-findings.md) | ten defects and several designs found in the real HIS at `~/Documents/HIS Project`, each with working code to copy | whoever owns that codebase. It is about **your services**, not about this integration |
| [upstream-issues/](upstream-issues/) | seven OpenELIS defects, written as reports that could be filed upstream | useful when OpenELIS behaves oddly. **Not** a description of normal operation — the integration works despite these, and each one says how |
| [audit.md](audit.md) | the September 2026 audit of this repository, and the plan that came out of it | history. Every phase is implemented; the file names in it predate the bridge's rewrite from C# to TypeScript and it says so |
| [acceptance.md](acceptance.md) | what was demonstrated, check by check, against the original brief | history, and the record of what "done" meant |

## The one thing worth carrying forward

The seven upstream reports were **written and never filed**. If this integration
goes into production, filing them is how the defects eventually stop being
yours to work around — particularly
[01](upstream-issues/01-task-poll-not-idempotent.md), which is the one the
bridge still carries containment for.
