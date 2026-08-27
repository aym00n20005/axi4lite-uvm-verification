# Bug reports

Every bug — injected for qualification or found genuinely — is recorded here,
per verification plan §7. A testbench that has never caught a bug is unproven.

| ID | Class | Where | Detected by | Status |
|---|---|---|---|---|
| [BUG-002](BUG-002.md) | injected | both slaves | SVA `a_bvalid_not_early` | detected, reverted |
| [BUG-007](BUG-007.md) | **genuine** | protocol checker | cover-count review | fixed in `ba344fa` |

## Outstanding injections — spec §9

| ID | Where | Blocked on |
|---|---|---|
| BUG-001 | UVM driver | no driver yet — UVM milestone |
| BUG-003 | memory slave `WSTRB` | run against the smoke bench (6 failures); §9 assigns it to the **scoreboard**, which does not exist yet |
| BUG-004 | `INT_STATUS` as plain RW | needs the RAL access-policy test — October |
| BUG-005 | interconnect decode | interconnect not built — September |
| BUG-006 | `COUNTER` vs `reset_stats` | directed test exists in `sanity_tb`; not yet run as a formal injection |

Numbering: spec §9 reserves 001–006 for the planned injections. Genuine finds
continue the same sequence from 007.

Both genuine finds so far are defects in the **protocol checker**, not the DUT,
and both were false confidence rather than missed detection: BUG-007 was a
cover point that could not fail to be covered, BUG-008 an assertion that failed
on correct hardware. The checker gets the same scrutiny as the design.
