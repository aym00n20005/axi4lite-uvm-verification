# Memory Slave — Architecture

**17 Aug 2026 · `rtl/axi4lite_mem_slave.sv`, spec v0.3 §6**

The AXI handshake skeleton is identical to the register slave — same
accept-flags, same combinational `do_write`, same bypass muxes, same
registered-response timing. That reasoning is in
[reg_slave_architecture.md](reg_slave_architecture.md) and is not repeated.

Duplicating it rather than factoring out a shared base module is deliberate:
each slave stays readable standalone, and the protocol logic is the part you
want to be able to point at in isolation. Two 200-line files beat one file
plus an abstraction whose only job is to hide the interesting part.

Only the differences are documented here.

---

## 1. What this slave does not have

| Absent | Why |
|---|---|
| `INT_STATUS`, `STATUS`, `COUNTER` | A memory slave has no side effects. Spec §6: errors are reported **on the bus only**. |
| Unimplemented-offset check | All 256 words are implemented. Everything above `0x13FF` is caught by the interconnect as DECERR and never arrives. |
| Reset on the memory array | Spec §6: *"reset does not clear memory contents. This matches real RAM."* |

Misalignment is the **only** error this slave can raise. That makes `wr_error`
a single term rather than the register slave's priority cascade, and there is
correspondingly no error-precedence question to answer.

## 2. Decode

```systemverilog
wire [WORD_BITS-1:0] wr_word = wr_addr[WORD_BITS+1:2];   // ADDR[9:2]
```

The base address needs no subtraction: `0x1000` has zero in its low ten bits,
so `ADDR[9:2]` indexes the region directly.

**Standalone, before the interconnect exists, an access to `0x1400` will alias
onto word 0 here.** That is not a defect in this module — routing is the
interconnect's responsibility, and it is exactly the responsibility BUG-005
injects a fault into. Worth knowing before the September bring-up, so the
aliasing is recognised as expected rather than chased as a bug.

## 3. `WSTRB` — the same signal, the opposite policy

Byte-lane masking is the whole job of the write path:

```systemverilog
always_ff @(posedge ACLK) begin
    if (mem_write) begin
        for (int b = 0; b < STRB_WIDTH; b++) begin
            if (wr_strb[b]) mem[wr_word][8*b +: 8] <= wr_data[8*b +: 8];
        end
    end
end
```

Two things about this loop are worth being able to explain.

**`WSTRB == 4'b0000` needs no special case.** Every lane is simply disabled,
nothing is written, and `BRESP` is already `OKAY` because misalignment is the
only error. Spec §6's "legal no-op returning OKAY" is *emergent from the loop*
rather than coded as an exception — which is the exact opposite of the register
slave, where the same pattern is an explicit `SLVERR` with `INT_STATUS[2]` set
(spec §5).

That contrast is the single best question to ask about this design: *the same
four bits mean "write these bytes" on one slave and "reject this transaction"
on the other, and both are correct.*

**There is no reset branch, and no `negedge ARESETn` in the sensitivity list.**
The absence is the implementation of spec §6. A reviewer scanning for a missing
reset will stop here, which is why the RTL says so in a comment at the point of
omission rather than only in this document.

## 4. Verification status

`tb/sanity_mem_tb.sv` — 27 checks, passing under Icarus 13.0 and under
Verilator 5.050 with the protocol checker bound. Covers both ends of the
region, each byte lane individually and cumulatively, a non-contiguous strobe,
the zero-strobe no-op, misaligned read and write, both AW/W orderings, and
survival of the array across a reset pulse.

**Negative control.** BUG-003 (spec §9 — *memory slave ignores WSTRB, always
writes all four bytes*) was injected and produced 6 failures. The most
damaging symptom was not a byte-lane mismatch but this:

```
FAIL   memory unchanged by zero strobe    0xffffffff  (expected 0x11bb33dd)
```

The "legal no-op" silently became a full-word overwrite. A bench that only
checked partial strobes against expected data would still have caught it, but
the zero-strobe case is the one that shows why it matters.

Spec §9 lists BUG-003 as caught by the **scoreboard**, not by a directed test.
That remains true and is the harder requirement — this bench catching it early
does not discharge it. The scoreboard must still catch it in September.
