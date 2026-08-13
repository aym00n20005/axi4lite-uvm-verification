# AXI4-Lite Protocol — Reference Card

**Day 2 notes · 13 Aug 2026.** Everything here maps to a specific assertion in
`tb/interface/axi4lite_if.sv` or a specific clause in `docs/dut_spec.md` v0.2.
If you can reproduce this file from memory, you know AXI4-Lite well enough to
defend this project.

---

## 1. The five channels

| Channel | Full name | Direction | Payload | Why it exists |
|---|---|---|---|---|
| **AW** | Write Address | master → slave | `AWADDR`, `AWPROT` | *Where* to write |
| **W**  | Write Data    | master → slave | `WDATA`, `WSTRB`   | *What* to write |
| **B**  | Write Response| slave → master | `BRESP`            | *Did it work* |
| **AR** | Read Address  | master → slave | `ARADDR`, `ARPROT` | *Where* to read |
| **R**  | Read Data     | slave → master | `RDATA`, `RRESP`   | *The data + did it work* |

Every channel carries exactly one pair of flow-control signals: `xVALID` from the
source, `xREADY` from the destination.

**The single most important structural fact:** AW and W are *separate channels
with separate handshakes*. There is no rule that says the address arrives first.
A master may send W before AW, or both in the same cycle. Spec §3 rule 4.
This is the thing everyone gets wrong first, and it is why the driver in this
project uses one `fork` thread per channel rather than a sequential FSM.

**Why five channels at all:** decoupling address from data lets a master issue
an address while the previous data is still moving, and lets reads and writes
progress independently. Full AXI4 exploits this with bursts and multiple
outstanding IDs; AXI4-Lite keeps the five-channel structure but drops bursts.
This DUT further caps it at **one outstanding write + one outstanding read**
(spec §1) — deliberately, to keep reorder buffers out of scope.

## 2. The handshake — one rule, and its consequences

> **A transfer occurs on the rising clock edge where `VALID` and `READY` are
> both high.** Nothing else counts as a transfer.

Three legal timings, all of which the testbench must produce:

```
  (a) VALID first          (b) READY first          (c) Same cycle
      ___                       ___                      ___
VALID_|   |___            _____|   |___           _____ |   |___
          ___             ___                            ___
READY ___|   |___        |      |___              _____ |   |___
          ^                     ^                        ^
       transfer              transfer                 transfer
```

Four rules fall out of it. These are the ones the checker asserts:

| # | Rule | Assertion |
|---|---|---|
| 1 | Once `VALID` is high it stays high until `READY` is sampled high. **A master may never withdraw a request.** | `a_awvalid_stable` and friends |
| 2 | `READY` may assert before, with, or after `VALID`. **No reverse dependency** — a slave may not wait to see `VALID` before deciding to assert `READY`, because a master that waits for `READY` would deadlock. | (structural; no assertion needed) |
| 3 | Payload is stable while `VALID` is high and `READY` is low. | `a_awaddr_stable`, `a_wdata_stable`, … |
| 4 | A response must not wait for its own `READY`. `BVALID` cannot be held back until `BREADY` appears. | `a_b_not_stalled`, `a_r_not_stalled` |

Rule 2 and rule 4 are the same idea seen from two sides: **the protocol forbids
circular waits.** If both ends could wait for the other, the bus deadlocks.

## 3. Ordering rules for this DUT

From spec §3:

- `BVALID` must not assert until **both** AW and W have been accepted (rule 5).
- `RVALID` must not assert until AR has been accepted (rule 6).
- All output `VALID`s are low while `ARESETn` is low (rule 7).

**Frozen timing decision (spec §3):** this DUT is *registered*. `BVALID` and
`RVALID` assert **no earlier than the cycle after** the accepts that enable
them. AMBA permits same-cycle assertion for a combinational slave; we exclude it
so the checker can use registered pending-flags. This is a tightening of the
spec, chosen on purpose.

## 4. Reading the checker

### 4.1 Why VALID-stability uses `|=>` and not `|->`

```systemverilog
property p_valid_stable(valid, ready);
    (valid && !ready) |=> valid;
endproperty
```

`|->` is *overlapping* implication: the consequent is checked in the **same**
cycle as the antecedent. `|=>` is *non-overlapping*: the consequent is checked
in the **next** cycle.

Here the antecedent `(valid && !ready)` already tells us `valid` is high *this*
cycle — asserting `valid` in the same cycle would be a tautology that can never
fail. The actual obligation is about the **next** cycle: having not been
accepted, `VALID` must still be there. Hence `|=>`.

> Interview version: "`|->` would have been vacuously true. The obligation the
> rule creates lands one cycle later, so the implication has to be
> non-overlapping."

### 4.2 What `disable iff (!ARESETn)` does

```systemverilog
default disable iff (!ARESETn);
```

Any property evaluation **in progress** when `ARESETn` drops is abandoned, not
failed. Without it, a reset asserted mid-transaction would fail every stability
assertion — `VALID` legitimately drops on reset — and the log would fill with
false failures on every reset test (`axi_reset_test`, F09).

Applied as `default`, it covers every property in the module. `a_reset_valids_low`
deliberately opts out with `disable iff (1'b0)`, because that assertion is
*about* what happens while reset is low. If it inherited the default it could
never fire.

### 4.3 Why response ordering triggers on VALID alone

```systemverilog
a_bvalid_not_early : assert property (BVALID |-> (aw_pend && w_pend));
```

Not `BVALID && BREADY`. This is the subtlest point in the file.

Imagine a broken slave that asserts `BVALID` immediately after AW, before W has
been accepted. If the master is slow to raise `BREADY`, W may well have been
accepted by the time the B handshake actually completes. A check written as
`(BVALID && BREADY) |-> (aw_pend && w_pend)` would then **pass on a genuinely
broken DUT** — the evidence has already been erased by the time it looks.

The spec requirement is about the moment of **assertion**, so the check has to
be about the moment of assertion too. v0.1 of the interface file got this wrong.

### 4.4 The pending flags, and why they re-arm

```systemverilog
if (b_done) begin
    aw_pend <= aw_acc;      // NOT <= 1'b0
    w_pend  <= w_acc;
end else begin
    if (aw_acc) aw_pend <= 1'b1;
    if (w_acc)  w_pend  <= 1'b1;
end
```

On the cycle the B handshake completes, the flags clear — but if a *new* AW is
accepted in that same cycle (legal, and exactly what `axi_b2b_test` does), a
plain `<= 1'b0` would drop it, and the next `BVALID` would falsely trip
`a_bvalid_not_early`. Assigning `aw_acc` clears and re-arms in one statement.

This is the bit of the checker most likely to bite during back-to-back testing.

### 4.5 What the assertions force the RTL to do

The checker pins the design contract more precisely than the prose spec does:

| Assertion | RTL consequence |
|---|---|
| `a_bvalid_not_early` + `a_b_not_stalled ##[0:8]` | `BVALID` asserts **exactly one cycle after the later of the AW/W accepts** |
| `a_single_outstanding_write` | `AWREADY`/`WREADY` must **drop** the cycle after both halves are accepted, and stay low until `BREADY` completes |
| `a_single_outstanding_read` | `ARREADY` must drop while `RVALID` is pending |
| `a_no_x_valids` / `a_no_x_readys` | every output register needs a reset value — no `X` out of reset |

Build the RTL to the assertions, not just to the prose. They are stricter.

## 5. Cycle-accurate picture of this DUT

### Write, AW and W in the same cycle

```
             T0      T1      T2
AWVALID    ‾‾‾‾‾\____
AWREADY    ‾‾‾‾‾\____          <- must drop at T1 (single outstanding)
WVALID     ‾‾‾‾‾\____
WREADY     ‾‾‾‾‾\____
aw_pend    ______/‾‾‾‾‾\____
w_pend     ______/‾‾‾‾‾\____
BVALID     ______/‾‾‾‾‾\____   <- exactly one cycle after the accepts
BREADY           ‾‾‾‾‾
             ^       ^
          accepts   b_done
```

### Write, W before AW (the case a lockstep driver never produces)

```
             T0      T1      T2      T3
WVALID     ‾‾‾‾‾\____
WREADY     ‾‾‾‾‾\____
w_pend     ______/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\____
AWVALID    ______________/‾‾‾‾‾\____
AWREADY    ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\____   <- still high: only w_pend is set
aw_pend    ______________________/‾‾‾‾‾\____
BVALID     ______________________/‾‾‾‾‾\____
```

`BVALID` follows the **later** accept. This is why the RTL needs two separate
accept-flags that combine, not a single sequential state machine — spec §3:
*"Rule 4 is the one you will get wrong first."*

### Read

```
             T0      T1      T2
ARVALID    ‾‾‾‾‾\____
ARREADY    ‾‾‾‾‾\____
ar_pend    ______/‾‾‾‾‾\____
RVALID     ______/‾‾‾‾‾\____
RDATA      ------< data >----
RREADY           ‾‾‾‾‾
```

## 6. Response encoding

| Code | Name | Meaning in this project |
|---|---|---|
| `2'b00` | OKAY | Normal completion |
| `2'b01` | EXOKAY | Exclusive access — **not used in AXI4-Lite** |
| `2'b10` | SLVERR | A slave owns this address but **rejected** the access |
| `2'b11` | DECERR | The interconnect **could not route** it at all |

The SLVERR/DECERR distinction is worth being able to say cleanly: *DECERR means
nobody owns the address; SLVERR means somebody owns it and said no.*

In this DUT: unmapped `0x1400+` → DECERR from the interconnect, never reaching a
slave. Misaligned, unimplemented register offset, and partial-strobe register
write → SLVERR from the owning slave.

## 7. Self-test

Answer these without looking. If any one stalls you, reread that section.

1. Why can't a slave wait to see `VALID` before asserting `READY`?
2. Why is `p_valid_stable` written with `|=>`?
3. A slave asserts `BVALID` one cycle after AW, ignoring W. Why would a check
   written as `(BVALID && BREADY) |-> (aw_pend && w_pend)` fail to catch it?
4. What does `disable iff (!ARESETn)` do, and which assertion in the file opts
   out of it, and why?
5. Why does `aw_pend <= aw_acc` on `b_done`, rather than `aw_pend <= 1'b0`?
6. DECERR vs SLVERR — one sentence each.
7. `WSTRB == 4'b0000` on a memory write vs. on a register write. Different
   outcomes — what and why? *(spec §5 and §6)*
8. Why is `COUNTER` 16 bits rather than 32?
9. Why does `STATUS.busy` cover the write path only?
10. On the third cycle of a stalled write address phase, which signals are
    guaranteed stable, and which assertion enforces it?
