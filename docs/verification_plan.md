# Verification Plan — AXI4-Lite Peripheral Subsystem

**Version 0.3**
**Author:** <your name> · Final-year ECE, Bengaluru
**DUT:** AXI4-Lite peripheral subsystem — register-file slave, memory slave, decoding interconnect
**Methodology:** SystemVerilog / UVM · SVA · functional coverage · UVM RAL
**Spec reference:** `docs/dut_spec.md` v0.3

---

## 1. Objective

Verify functional correctness and AXI4-Lite protocol compliance of a peripheral subsystem consisting of an address-decoding interconnect, a register-file slave with mixed access policies, and a byte-addressable memory slave.

Verification is complete when every feature in §3 has a passing test, the coverage model in §5 reaches its stated goals, and every uncovered bin has a written justification.

## 2. Scope

**In scope:** AXI4-Lite protocol compliance across all five channels, AW/W ordering independence, register access policies (RW / RO / W1C), reserved-bit behaviour, byte enables, address decode and routing, the three error classes (DECERR / SLVERR / OKAY), alignment checking, reset behaviour, backpressure tolerance.

**Out of scope, with rationale:**

| Excluded | Why |
|---|---|
| AXI4 bursts, IDs, out-of-order completion | AXI4-Lite chosen so methodology is established before protocol complexity. Planned extension. |
| Multiple outstanding transactions | Capped at one read + one write by spec §1. Avoids reorder buffers and response queues, which are a different project. |
| Low power / UPF | Single always-on domain. |
| Clock domain crossing | Single clock domain by spec. |
| Gate-level simulation, physical timing | RTL-level project. |

## 3. Feature list and verification method

| ID | Feature | Description | Primary method | Secondary |
|---|---|---|---|---|
| F01 | Write path | AW + W accepted, B returned with OKAY | Directed + random | Scoreboard |
| F02 | Read path | AR accepted, R returns correct data + OKAY | Directed + random | Scoreboard |
| F03 | AW/W independence | AW and W accepted in any order, incl. same cycle | Constrained random | Cover property |
| F04 | VALID stability | VALID held until READY sampled high | SVA | — |
| F05 | Payload stability | ADDR/DATA/STRB stable while VALID high, READY low | SVA | — |
| F06 | Response ordering | BVALID only after both AW and W accepted; RVALID only after AR | SVA | Directed |
| F07 | No response stalling | BVALID/RVALID do not wait for BREADY/RREADY | SVA | Directed |
| F08 | Single outstanding | No second AW/W accepted while a B is pending | SVA | Directed |
| F09 | Reset behaviour | VALIDs low in reset; recovery from reset mid-transaction | Directed | SVA |
| F10 | Register RW access | CTRL, CONFIG, SCRATCH, INT_ENABLE writable and read back | RAL | Scoreboard |
| F11 | Register RO access | STATUS, COUNTER, ID ignore writes, return OKAY | RAL | Directed |
| F12 | Register W1C access | INT_STATUS bit clears on write-1, unchanged on write-0 | RAL | Directed |
| F13 | Reserved fields | Reserved bits read 0 and cannot retain written values | Directed | RAL |
| F14 | Memory word access | Full 32-bit write/read across 1 KB | Random | Scoreboard |
| F15 | Byte enables | Partial writes modify only strobed bytes; 4'b0000 is a legal no-op | Constrained random | Scoreboard |
| F16 | Register strobe rule | Partial-strobe register write → SLVERR, register unchanged | Directed | Scoreboard |
| F17 | Address decode | Transactions routed to the correct slave | Directed + random | Scoreboard |
| F18 | Unmapped access | 0x1400 and above → DECERR, not forwarded | Directed | Scoreboard |
| F19 | Unimplemented offset | Reg offsets 0x20–0xFFF → SLVERR | Directed | Scoreboard |
| F20 | Alignment | ADDR[1:0] != 0 → SLVERR, no state change | Directed + random | Scoreboard |
| F21 | Error precedence | Correct single response and single INT_STATUS bit when errors collide | Directed | Scoreboard |
| F22 | INT_STATUS events | Each of the four events sets its bit | Directed | Scoreboard |
| F23 | Set-vs-clear collision | Event set beats simultaneous W1C clear | Directed | — |
| F24 | STATUS.busy | Reads 1 during in-flight write, 0 otherwise | Directed | — |
| F25 | STATUS.error | Reflects last completed register transaction | Directed | — |
| F26 | COUNTER behaviour | Increments on enable; reset_stats has priority; wraps at 0xFFFF | Directed | Scoreboard |
| F27 | COUNTER overflow event | Wrap sets INT_STATUS[3] | Directed | — |
| F28 | Backpressure | Arbitrary READY delays tolerated on all channels | Constrained random | Coverage |
| F29 | Back-to-back | Zero-gap consecutive transactions | Directed | Coverage |

## 4. Verification environment

```
                        uvm_test
                           │
                       axi_env
        ┌──────────────┬────┴─────┬──────────────┐
        │              │          │              │
  axi_master_agent  scoreboard  coverage     axi_reg_block
   ┌────┴────┐      (ref model)  collector      (RAL)
   │sequencer│                                     │
   │ driver  │◀────────── reg_adapter ─────────────┘
   │ monitor │
   └────┬────┘
        │
    axi4lite_if ──── axi4lite_protocol_checker (SVA, bound)
        │
       DUT
```

All of it exists. The RAL model and its adapter are the last components added;
`uvm_reg_predictor` sits on the monitor's analysis port, so the mirror is updated
from **observed pin activity** rather than from the operations the sequence
issued — see `tb/ral/axi_reg_adapter.sv` for why that distinction is the whole
point.

**Design decisions:**

- **Driver uses concurrent per-channel threads** (`fork ... join_none`), not a sequential FSM. AW, W, B, AR and R are independent; a lockstep driver would never exercise F03 and would hide slave-side ordering bugs. The cover property `c_w_before_aw` exists to prove this is actually happening.
- **Monitor is fully passive** and reconstructs transactions from pins only. It shares no state with the driver, so a driver defect cannot mask itself.
- **Reference model** is an associative array for memory and a mirrored register model for the register file, including reserved-bit masking so that expected read data accounts for F13.
- **Agent is configurable** active or passive, so it can be reused to observe a second port later.

## 5. Coverage model

| Covergroup | Bins | Goal |
|---|---|---|
| `cg_transaction_type` | read, write | 100% |
| `cg_address_region` | reg implemented, reg unimplemented, mem, unmapped-low (0x1400–0x1FFF), unmapped-high | 100% |
| `cg_register_offset` | one bin per implemented register | 100% |
| `cg_register_access_type` | RW, RO, W1C | 100% |
| `cg_alignment` | aligned, misaligned (offset 1, 2, 3) | 100% |
| `cg_wstrb` | all 16 patterns incl. 4'b0000 | ≥ 90% |
| `cg_response` | OKAY, SLVERR, DECERR | 100% |
| `cg_error_source` | unmapped, unimplemented offset, partial strobe, misaligned | 100% |
| `cg_int_status_event` | one bin per INT_STATUS bit set | 100% |
| `cg_valid_delay` | 0, 1–3, 4–10, >10 cycles | 100% |
| `cg_backpressure` | READY delay 0, 1–3, 4–10, >10 cycles | 100% |
| `cg_aw_w_order` | AW first, W first, same cycle | 100% |
| `cg_reset` | reset idle, reset mid-write, reset mid-read | 100% |

**Crosses:**

- `cg_transaction_type × cg_address_region` — both directions exercised in every region
- `cg_wstrb × address_alignment` — partial writes at each byte offset
- `cg_transaction_type × cg_backpressure` — reads and writes both stalled
- `cg_register_access_type × cg_response` — each access class seen with each legal response

**Closure criterion:** 100% on all groups except `cg_wstrb`, where every uncovered bin must be individually justified in writing. "We ran out of time" is not a justification; "this strobe pattern is unreachable given the register strobe rule in spec §5" is.

## 6. Test list

| Test | Purpose | Features |
|---|---|---|
| `axi_smoke_test` | Single write, single read, readback | F01, F02 |
| `axi_random_test` | Constrained-random mixed traffic | F01, F02, F14, F28 |
| `axi_reset_test` | Reset during idle and mid-transaction | F09 |
| `axi_order_test` | Force AW-first, W-first and same-cycle | F03 |
| `axi_wstrb_test` | Sweep byte-enable patterns on memory | F15 |
| `axi_reg_strobe_test` | Partial-strobe register write | F16, F22 |
| `axi_align_test` | Misaligned accesses to both slaves | F20 |
| `axi_decode_test` | Each slave, unmapped-low, unmapped-high | F17, F18, F19 |
| `axi_error_priority_test` | Colliding error conditions | F21 |
| `axi_ral_test` | RAL hw_reset + bit_bash + access-policy sweep | F10–F13 |
| `axi_int_status_test` | Each event source; set-vs-clear collision | F22, F23 |
| `axi_status_test` | busy during in-flight write; error tracking | F24, F25 |
| `axi_counter_test` | Enable, reset_stats priority, wrap to overflow | F26, F27 |
| `axi_backpressure_test` | Extreme READY delays on all channels | F28 |
| `axi_b2b_test` | Zero-gap consecutive transactions | F29, F08 |
| `axi_regression_test` | All fifteen sequences in one simulation | all |
| `axi_multiseed_test` | Eight seeds of `axi_random_seq` in one simulation | F01, F02, F03, F14, F28, F29 |

**Every test above exists.** The thirteen that did not are written as
*sequences* with thin test wrappers, so each is still a test of its own and all
of them can run inside a single simulation — which is what makes a regression
affordable when the only UVM simulator is reached through a browser. See
`tb/sequences/axi_directed_seqs.sv`.

Two features in §3 are reachable only in UVM and nowhere else: **F24**
(`STATUS.busy`, which needs a read concurrent with an in-flight write) and
**F27** (`COUNTER` overflow, which needs 65,536 cycles). Everything else is also
covered by a local bench.

## 7. Bug tracking

Every bug — injected for qualification or found genuinely — is recorded in `docs/bug_reports/` with:

| Field | Content |
|---|---|
| ID | BUG-00n |
| Detected by | SVA / scoreboard / RAL / directed test |
| Test + seed | the failing run |
| Expected | what spec §x requires |
| Actual | what the DUT did |
| Evidence | waveform, cycle numbers |
| Root cause | the actual RTL defect |
| Fix | the change made |
| Regression | confirmation all tests pass after the fix |

**Testbench qualification:** six bugs (spec §9) are injected on a separate branch to prove the environment detects them. A testbench that has never caught a bug is unproven.

## 8. Delivery status

The plan originally carried dates. They are removed: everything below is done,
and a date on a finished item says nothing a reader needs.

| Deliverable | Status |
|---|---|
| Both slaves' RTL, UVM agent, smoke test, protocol checker bound and proven by a deliberate break | done |
| Interconnect, address decode, `DECERR`, scoreboard with a spec-derived reference model | done |
| RAL model, full coverage model, backpressure randomisation | done — RAL **generated** from `scripts/regmap.yaml`, not hand-written |
| Coverage closure, regression flow, bug database, formal experiment | done |
| Documentation | done |

Traceability against §3 is generated rather than asserted:
[traceability.md](traceability.md), regenerated by `make vplan` from this
document's own feature table, `scripts/testlist.yaml` and the latest regression.

## 9. Open questions — resolved

Kept deliberately rather than silently decided in RTL. All three are now
answered, and each answer is a decision with a reason rather than a default that
was never revisited.

### 1. Should writes to RO registers return `OKAY` or `SLVERR`?

**`OKAY`, unchanged.** The question was whether integrating the RAL would argue
for `SLVERR`; it argues the other way.

`uvm_reg_bit_bash_seq` writes to every register including the read-only ones, and
treats a non-`UVM_IS_OK` status as an error in its own right — so an `SLVERR` on
a RO write would make the standard access-policy sequence fail on a correct DUT.
The adapter would then have to special-case it, which means teaching the RAL
about a decision the RAL exists to check.

Verified by `axi_ral_test`: `regmodel.ID.write(status, 0)` returns `UVM_IS_OK`
and `ID` still reads `0xDEAD_BEEF`.

### 2. Should the memory slave expose any error status?

**Bus-error-only, unchanged**, and the interconnect made the reason sharper than
it was in August.

With both slaves in one design, a misaligned *register* access sets
`INT_STATUS[1]` and a misaligned *memory* access sets nothing. That asymmetry is
now a **discriminating check** in `axi_align_seq` — the same offence, two slaves,
two different side effects — and it only became testable when both slaves shared
an address map. Giving the memory slave its own status register would delete a
check rather than add one.

### 3. Is `STATUS.busy` observable often enough to close its coverage bin?

**No, not by accident — an explicit concurrent read+write sequence is needed, and
`axi_status_seq` is it.** The August answer would have been "issue a read while a
write is in flight". The interconnect changed the shape of the problem and the
sequence documents why:

`busy` tracks the **register slave's** write path. Driving the slave directly, a
slow `BREADY` from the master holds the slave's `BVALID` high and keeps `busy`
asserted for as long as you like. Through the interconnect it does not — the
interconnect raises its *own* `BREADY` the cycle the slave responds, so the
slave's `busy` window is two or three cycles wide regardless of what the master
does. The master's `b_ready_delay` stalls the interconnect, not the slave.

So the window is **swept** rather than aimed at: a non-blocking write is issued
and a `STATUS` read follows it at every delay from 0 to 15. Observing `busy == 1`
at least once is the claim; the sweep is how.

This is a real consequence of adding a component, found by trying to write the
test rather than by reasoning about it, and it is the kind of thing an open
question is *for*.

## 10. References

- ARM AMBA AXI Protocol Specification — AXI4-Lite chapter
- IEEE 1800-2017 SystemVerilog LRM · UVM 1.2 / IEEE 1800.2
- OpenHW Group `core-v-verif` — referenced for vplan structure and bug-tracking practice; environment not used, as it requires commercial simulators
