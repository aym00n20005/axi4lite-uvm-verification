# Bug reports

Every bug — injected for qualification or found genuinely — is recorded here,
per verification plan §7. A testbench that has never caught a bug is unproven.

## The six planned injections — spec §9, all discharged

| ID | Where | Detected by | Status |
|---|---|---|---|
| [BUG-001](BUG-001.md) | **driver** | SVA `a_awvalid_stable` | detected |
| [BUG-002](BUG-002.md) | both slaves | SVA `a_bvalid_not_early` | detected, reverted |
| [BUG-003](BUG-003.md) | memory slave | **scoreboard**, as §9 requires | detected, reverted |
| [BUG-004](BUG-004.md) | `INT_STATUS` as plain RW | a directed check and the formal proof, both measured. The §9-assigned RAL detection is **predicted, not yet measured** — the RAL's first run found [BUG-013](BUG-013.md) instead | detected, reverted |
| [BUG-005](BUG-005.md) | interconnect decode | **scoreboard + decode test**, as §9 requires; also random traffic, first seed | detected, reverted |
| [BUG-006](BUG-006.md) | register slave `COUNTER` | **directed test**, as §9 requires; also the scoreboard | detected, reverted |

Five of the six were caught by the mechanism the specification assigned it,
before any of those mechanisms existed. That is what §9 was for.

BUG-004 is the exception and it is stated plainly: it was caught, twice, but not
yet by the RAL that §9 names — because the RAL's first execution found a defect
in its own adapter. That claim stays open until a clean `axi_ral_test` runs.

## Genuine finds

| ID | Where | Detected by | Status |
|---|---|---|---|
| [BUG-007](BUG-007.md) | protocol checker | cover-count review | fixed |
| [BUG-008](BUG-008.md) | protocol checker | random traffic, first run | fixed |
| [BUG-009](BUG-009.md) | driver | a second DUT shifted the schedule | fixed |
| [BUG-010](BUG-010.md) | `axi_transaction` constraints | **slang elaboration**, in 0.2 s | fixed |
| [BUG-011](BUG-011.md) | scoreboard — no reset handling | `axi_reset_seq`, first run on Xcelium | fixed |
| [BUG-012](BUG-012.md) | scoreboard — `STATUS.error` on an overlapped read | `axi_status_seq`, first run on Xcelium | fixed |
| [BUG-013](BUG-013.md) | RAL adapter — a constraint that randomised what it pinned | `axi_ral_test`, first run that reached the RAL | fixed |
| [BUG-014](BUG-014.md) | driver — an in-flight transaction nothing retired on reset | `axi_reset_seq`, watchdog | fixed |

Numbering: spec §9 reserves 001–006 for the planned injections. Genuine finds
continue the same sequence from 007.

**All eight genuine finds are in the testbench, not the DUT.** BUG-007 was a cover
point that could not fail to be covered; BUG-008 an assertion that failed on
correct hardware; BUG-009 a driver race that passed for eleven days because the
timing happened to be safe; BUG-010 two constraints written in a form the LRM
grammar does not permit, accepted by the only simulator that had ever read them;
BUG-011 a reference model that did not know reset had happened; BUG-012 a
reference model predicting a field it cannot place in time; BUG-013 a constraint
that randomised the very field it appeared to pin; BUG-014 a transaction stranded
in a thread that reset destroyed.

None was a missed detection. Each was false confidence of a different kind — a
metric that could not fail, a checker that cried wolf, a race that had been
lucky, source that meant something other than what it said, and twice a model
that reported a correct DUT as broken.

**Five of the eight were found by the tests written last**, which is the argument
for finishing a test list rather than stopping when the coverage number looks
acceptable. F09, F24 and the RAL are the parts nothing had ever exercised, and
every one of them found a defect the first time it ran.

BUG-010 and BUG-013 are worth reading as a pair. Both are constraints that
compile, elaborate and mean something other than what they say. BUG-010 was
ill-typed, so a conformant front end found it in 0.2 seconds; BUG-013 is
perfectly well-typed, so **no parser could find it** and it took running the
thing. That is the honest limit of the elaboration gate: `make elab` proves the
source is legal, not that it is right.

That is worth stating plainly rather than hiding: the environment has found more
defects in itself than in the design it is checking. The RTL was written from a
specification that had been corrected first; the testbench was written against a
moving target.

## What caught what

Each mechanism, and the first defect that proved it works. A mechanism that has
never caught anything is unproven, whatever its coverage says.

| Mechanism | Proved by |
|---|---|
| SVA protocol checker | BUG-002 — and BUG-001, which proves it catches a *master*-side violation too |
| Spec-derived scoreboard | BUG-003, BUG-005 |
| Directed tests | BUG-006 |
| Generated RAL model | BUG-004 |
| Constrained-random traffic | BUG-005, on the first seed, with no knowledge of the map |
| Local elaboration (slang) | BUG-010 |
| Bounded model check | the set-vs-clear inversion — see [formal_notes.md](../formal_notes.md), where 4,576 simulation checks passed on the same design |
| Cover-count review | BUG-007 |
| Directed tests written last (F09, F24) | BUG-011, BUG-012 — both in the reference model |
| Running the RAL at all | BUG-013 — in the adapter, the one file nothing else executes |
| The inactivity watchdog | BUG-014 — a bus that went quiet, with no assertion and no mismatch to report it |
