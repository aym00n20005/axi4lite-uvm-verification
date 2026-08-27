# Bug reports

Every bug — injected for qualification or found genuinely — is recorded here,
per verification plan §7. A testbench that has never caught a bug is unproven.

| ID | Class | Where | Detected by | Status |
|---|---|---|---|---|
| [BUG-002](BUG-002.md) | injected | both slaves | SVA `a_bvalid_not_early` | detected, reverted |
| [BUG-003](BUG-003.md) | injected | memory slave | **scoreboard**, as §9 requires | detected, reverted |
| [BUG-007](BUG-007.md) | **genuine** | protocol checker | cover-count review | fixed in `ba344fa` |

## Outstanding injections — spec §9

| ID | Where | Blocked on |
|---|---|---|
| BUG-001 | UVM driver | no driver yet — UVM milestone |
| BUG-004 | `INT_STATUS` as plain RW | needs the RAL access-policy test — October |
| BUG-005 | interconnect decode | interconnect not built — September |
| BUG-006 | `COUNTER` vs `reset_stats` | directed test exists in `sanity_tb`; not yet run as a formal injection |

Numbering: spec §9 reserves 001–006 for the planned injections. Genuine finds
continue the same sequence from 007.

All three genuine finds so far are in the **testbench**, not the DUT. BUG-007
was a cover point that could not fail to be covered; BUG-008 an assertion that
failed on correct hardware; BUG-009 a driver race that passed for eleven days
because the timing happened to be safe. None was a missed detection — each was
false confidence of a different kind.

That is worth stating plainly rather than hiding: the environment has found
more defects in itself than in the design it is checking. The RTL was written
from a specification that had been corrected first, and the testbench was
written under time pressure against a moving target.
