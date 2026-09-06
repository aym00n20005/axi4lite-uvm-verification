# Bug reports

Every bug — injected for qualification or found genuinely — is recorded here,
per verification plan §7. A testbench that has never caught a bug is unproven.

## The six planned injections — spec §9, all discharged

| ID | Where | Detected by | Status |
|---|---|---|---|
| [BUG-001](BUG-001.md) | **driver** | SVA `a_awvalid_stable` | detected |
| [BUG-002](BUG-002.md) | both slaves | SVA `a_bvalid_not_early` | detected, reverted |
| [BUG-003](BUG-003.md) | memory slave | **scoreboard**, as §9 requires | detected, reverted |
| [BUG-004](BUG-004.md) | `INT_STATUS` as plain RW | **RAL `bit_bash`**, as §9 requires; also a directed check and the formal proof | detected, reverted |
| [BUG-005](BUG-005.md) | interconnect decode | **scoreboard + decode test**, as §9 requires; also random traffic, first seed | detected, reverted |
| [BUG-006](BUG-006.md) | register slave `COUNTER` | **directed test**, as §9 requires; also the scoreboard | detected, reverted |

Every one was caught by the mechanism the specification assigned it in August,
before any of those mechanisms existed. That is what §9 was for.

## Genuine finds

| ID | Where | Detected by | Status |
|---|---|---|---|
| [BUG-007](BUG-007.md) | protocol checker | cover-count review | fixed |
| [BUG-008](BUG-008.md) | protocol checker | random traffic, first run | fixed |
| [BUG-009](BUG-009.md) | driver | a second DUT shifted the schedule | fixed |
| [BUG-010](BUG-010.md) | `axi_transaction` constraints | **slang elaboration**, in 0.2 s | fixed |

Numbering: spec §9 reserves 001–006 for the planned injections. Genuine finds
continue the same sequence from 007.

**All four genuine finds are in the testbench, not the DUT.** BUG-007 was a cover
point that could not fail to be covered; BUG-008 an assertion that failed on
correct hardware; BUG-009 a driver race that passed for eleven days because the
timing happened to be safe; BUG-010 two constraints written in a form the LRM
grammar does not permit, accepted by the only simulator that had ever read them.

None was a missed detection. Each was false confidence of a different kind — a
metric that could not fail, a checker that cried wolf, a race that had been
lucky, and source that meant something other than what it said.

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
