# Project Walkthrough

**A complete explanation, from zero.** If you can follow this document you can
defend every line in the repository.

Nothing here is a summary of what the code *should* do. Every claim is something
that was run and observed, and where a claim is not backed by a run it says so.

Parts 0–6 were written when the project had two slaves, an agent, a scoreboard
and a coverage model. They are unchanged, because that is the order the thinking
happened in and the reasoning is the point. Parts 7–10 cover what was still
missing then: the interconnect, the generated RAL, the flow, the formal
experiment, and the measurement of the AI layer.

---

# Part 0 — The one-paragraph version

There is a small piece of hardware: two AXI4-Lite slave devices, one holding
eight control registers and one holding a kilobyte of memory. The hardware is
deliberately simple. Everything interesting is in the machinery built to check
it: a written specification that was corrected before any hardware existed, 23
protocol assertions bound to the design, a UVM testbench that generates random
traffic, and a reference model that independently predicts what the hardware
should do and compares.

The testbench has found ten bugs. Six were planted on purpose to prove the
testbench works, and each was caught by the mechanism the specification assigned
it before any of those mechanisms existed. **Four were real, and all four were in
the testbench itself.**

There is also one defect that no test in this project can find, and a bounded
model check finds it in under a second. That is Part 8, and it is the most
useful thing here.

---

# Part 1 — Why verification is a separate job

If you write a piece of hardware and then test it yourself, you test it against
the same misunderstanding you built it with. If the specification says "the
counter clears when you write bit 1" and you misread that as bit 0, you will
write the hardware to use bit 0 and then write a test that checks bit 0. The
test passes. The hardware is wrong.

That is the whole reason verification exists as a discipline, and it drives
almost every structural decision in this project:

- The **specification** is the source of truth, and it is corrected *before* the
  hardware, never after.
- The **reference model** is written from the specification, not from the
  hardware. A model written by reading the hardware agrees with the hardware by
  construction and checks nothing.
- The **monitor** watches the physical wires and has no access to the thing that
  drives them. If it asked the driver what it sent, a driver bug would become
  invisible.
- The **assertions** are bound to the design from outside, and they constrain
  both sides of the interface — the design *and* the testbench driving it.

Each of those has already caught something. Part 6 lists them.

---

# Part 2 — AXI4-Lite, from nothing

## 2.1 What a bus is for

A processor needs to read and write registers inside a peripheral. AXI4-Lite is
a set of rules for how those two chips talk over wires.

## 2.2 The five channels

AXI4-Lite splits a conversation into five independent **channels**. Each channel
carries some signals in one direction plus two flow-control signals.

| Channel | Direction | Carries | Purpose |
|---|---|---|---|
| **AW** | master → slave | `AWADDR` | *where* to write |
| **W** | master → slave | `WDATA`, `WSTRB` | *what* to write |
| **B** | slave → master | `BRESP` | *did it work* |
| **AR** | master → slave | `ARADDR` | *where* to read |
| **R** | slave → master | `RDATA`, `RRESP` | *the data, and did it work* |

"Master" is whoever starts the transaction — here, the testbench. "Slave" is
whoever answers — here, the register file or the memory.

**Why split address from data?** Because they can then move independently. A
master can send an address while previous data is still in flight. Full AXI4
exploits this heavily with bursts; AXI4-Lite keeps the five-channel skeleton and
drops the complexity.

**The fact that matters most in this project:** AW and W are *separate channels
with separate handshakes*. Nothing says the address arrives first. `W` before
`AW` is legal. Both in the same cycle is legal. A slave must handle all three
orderings.

## 2.3 The handshake — one rule

> A transfer happens on the rising clock edge where `VALID` and `READY` are
> **both high**. Nothing else is a transfer.

`VALID` says "I have something for you." `READY` says "I can take it." Both
high on a clock edge means it moved.

Three legal timings:

```
  (a) VALID first          (b) READY first          (c) Same cycle
      ___                       ___                      ___
VALID_|   |___            _____|   |___           _____ |   |___
          ___             ___                            ___
READY ___|   |___        |      |___              _____ |   |___
          ^                     ^                        ^
       transfer              transfer                 transfer
```

Four consequences follow, and they are the assertions in Part 4:

1. Once `VALID` goes high it **stays** high until `READY` is seen high. A master
   may not withdraw a request it has committed to.
2. `READY` may come before, with, or after `VALID`. **No reverse dependency** —
   a slave may not wait to see `VALID` before deciding to assert `READY`.
3. The payload stays **stable** while `VALID` is high and `READY` is low.
4. A response must not wait for its own `READY`.

**Rules 2 and 4 are the same idea: no circular waits.** If both ends could wait
for the other, the bus deadlocks. That is the answer to "why two signals instead
of one strobe?"

## 2.4 What the response codes mean

| Code | Name | Meaning here |
|---|---|---|
| `2'b00` | OKAY | normal completion |
| `2'b10` | SLVERR | a slave owns this address but **rejected** the access |
| `2'b11` | DECERR | nothing owns this address; it could not be **routed** |

The distinction is worth being able to say cleanly: *DECERR means nobody owns
the address; SLVERR means somebody owns it and said no.*

---

# Part 3 — The hardware

Two slaves, `rtl/axi4lite_reg_slave.sv` and `rtl/axi4lite_mem_slave.sv`.

## 3.1 The register slave

Eight 32-bit registers at offsets `0x00` to `0x1C`. Each has an **access
policy**:

| Offset | Name | Policy | What it does |
|---|---|---|---|
| 0x00 | `CTRL` | RW | `[0]` enable, `[1]` reset_stats |
| 0x04 | `STATUS` | RO | `[0]` busy, `[1]` error |
| 0x08 | `CONFIG` | RW | 8 bits implemented |
| 0x0C | `INT_ENABLE` | RW | 4 bits |
| 0x10 | `INT_STATUS` | W1C | 4 interrupt flags |
| 0x14 | `SCRATCH` | RW | all 32 bits, no side effects |
| 0x18 | `COUNTER` | RO | 16-bit, free-running |
| 0x1C | `ID` | RO | constant `0xDEADBEEF` |

- **RW** — write it, read it back.
- **RO** — writes are accepted and *discarded*, and still return OKAY.
- **W1C** — "write 1 to clear". Writing a 1 to a bit clears it; writing 0 leaves
  it alone. Used for interrupt flags, so software can clear the ones it has
  handled without disturbing the others.

**Reserved bits read as 0 and cannot store data.** Write `0xFFFFFFFF` to
`CONFIG` and reading gives `0x000000FF`. In the hardware this is not a
behaviour that was implemented — the register is *physically eight bits wide*:

```systemverilog
logic [7:0] config_q;                     // not [31:0]
...
R_CONFIG : rd_mux = {24'b0, config_q};    // zeros supplied on read
```

There is no possible bug that makes a reserved bit remember something, because
there is no flip-flop there to remember it.

## 3.2 The heart of the register slave: two accept-flags

This is the single most important piece of hardware in the project.

Because AW and W are independent, the slave cannot use a state machine that
walks AW → W → B. It needs to accept either half first. So it keeps two
independent flags:

```systemverilog
assign AWREADY = !aw_captured && !bvalid_q;
assign WREADY  = !w_captured  && !bvalid_q;

wire do_write = (aw_captured || aw_hs) && (w_captured || w_hs) && !bvalid_q;
```

Read `do_write` carefully: it is true on the cycle the **later** of the two
halves is accepted, whichever that is. Registering it into `bvalid_q` therefore
places the response exactly one cycle after that later accept.

Each `READY` has two terms and both are load-bearing:

- `!aw_captured` — we are not already holding an unmatched address.
- `!bvalid_q` — no response is outstanding. **This is what enforces
  single-outstanding.** Without it, `AWREADY` would rise again the cycle after
  the write commits, while the response was still waiting.

### The bypass mux

```systemverilog
wire [31:0] wr_data = w_captured ? wdata_q : WDATA;
```

On the commit cycle, one half may have been latched several cycles ago while the
other is being accepted *right now* and is only on the wire, not in its latch.
Without this mux, a same-cycle AW+W write uses stale latched data.

We deliberately broke this on 16 August. The signature is unmistakable: **a
register reads back the value from the transaction before it.**

## 3.3 Error precedence

When several things are wrong at once, exactly one response is given and exactly
one interrupt flag is set. The hardware expresses this as a strict cascade:

```systemverilog
wire wr_err_misalign = wr_misalign;
wire wr_err_unimpl   = !wr_misalign && !wr_implemented;
wire wr_err_strobe   = !wr_misalign && wr_implemented && !(&wr_strb);
```

Each term excludes the ones above it, so exactly one is ever true. An access to
`0x101` is both misaligned *and* unimplemented; it sets the misaligned flag
only.

And every error path is factored out of one write-enable:

```systemverilog
wire reg_write = do_write && !wr_error;
```

The specification's rule "no error condition modifies any state" is enforced in
**one place**. That is the answer to "how do you know a failed write can't
corrupt a register?"

## 3.4 The memory slave, and the same signal meaning the opposite thing

256 words. The whole job of the write path is byte masking:

```systemverilog
always_ff @(posedge ACLK) begin           // note: no reset
    if (mem_write)
        for (int b = 0; b < 4; b++)
            if (wr_strb[b]) mem[wr_word][8*b +: 8] <= wr_data[8*b +: 8];
end
```

`WSTRB` is four bits, one per byte. Bit *n* set means "write byte *n*". This is
how a processor writes a single byte inside a 32-bit word.

**Two absences in that code are the specification:**

- There is **no reset** on the memory. Spec §6 says reset must not clear it,
  because real RAM does not lose its contents on reset. The missing reset *is*
  the requirement.
- `WSTRB == 4'b0000` needs **no special case**. Every lane is disabled, nothing
  is written, and the response is already OKAY. The spec's "legal no-op" falls
  out of the loop rather than being coded as an exception.

And here is the contrast worth memorising:

| | register slave | memory slave |
|---|---|---|
| `WSTRB = 4'b1111` | normal write | normal write |
| `WSTRB = 4'b0011` | **SLVERR**, register unchanged | writes bytes 0 and 1 |
| `WSTRB = 4'b0000` | **SLVERR** | **OKAY**, nothing written |

**The same four bits mean "write these bytes" on one slave and "reject this
transaction" on the other, and both are correct.** Partial writes to a control
register are almost always a software bug, so the register file refuses them;
partial writes to memory are ordinary.

## 3.5 Two contradictions found in the specification

While deriving the hardware architecture on paper — *before writing any
hardware* — four problems surfaced in the frozen specification. Two were genuine
contradictions.

**The decode.** §5 said "register selected by `ADDR[7:2]`". §4 said offsets
`0x20`–`0xFFF` must return SLVERR. `ADDR[7:2]` only spans the low 256 bytes, so
offset `0x100` would have *aliased onto `CTRL`* and been serviced normally.
Those two clauses cannot both be satisfied.

**`STATUS.error`.** §5 said the bit is "cleared by the next register transaction
that completes with OKAY". But *reading `STATUS` is itself such a transaction*,
so the read that observes the error would destroy it. Self-referential.

Both were fixed in the document first, the specification went to v0.3, and the
hardware was written afterwards. Every revision now has a test that would fail
under the old wording — that traceability is in `dut_spec.md` §10.

---

# Part 4 — The assertions

`tb/interface/axi4lite_if.sv` holds 23 assertions and 14 cover properties.
They are **bound** to the design rather than written inside it, so the hardware
stays clean and the checker can be removed from a build by not compiling one
file.

## 4.1 What an assertion is

A statement of something that must always be true, checked automatically on
every clock cycle for the whole simulation. If it is ever false the simulator
stops and says so. You do not have to think of a test case; the assertion
watches everything you ever run.

## 4.2 Reading the notation

```systemverilog
property p_valid_stable(valid, ready);
    (valid && !ready) |=> valid;
endproperty
```

- `|=>` means *"if the left side is true, the right side must be true on the
  **next** cycle."*
- `|->` is the same but for the **same** cycle.

Why `|=>` here? The left side already says `valid` is high *this* cycle, so
requiring `valid` this cycle would be a tautology that can never fail. The
obligation is about the next cycle. Getting this wrong gives you an assertion
that is always true and checks nothing.

```systemverilog
default disable iff (!ARESETn);
```

Any check in progress when reset arrives is **abandoned, not failed** — `VALID`
legitimately drops on reset. Exactly one assertion opts out of this, and it is
the one that is *about* reset:

```systemverilog
a_reset_valids_low : assert property (
    disable iff (1'b0)
    (!ARESETn) |-> (!AWVALID && !WVALID && !BVALID && !ARVALID && !RVALID))
```

**That override caught a real bug** on the driver's very first run against pins.
Every other assertion was switched off in that window.

## 4.3 The subtlest one

```systemverilog
a_bvalid_not_early : assert property (BVALID |-> (aw_pend && w_pend));
```

Note it triggers on `BVALID` **alone**, not on `BVALID && BREADY`.

Imagine a broken slave that raises `BVALID` immediately after AW, ignoring W. If
the master is slow to accept the response, W will probably have arrived by the
time the handshake completes. A check written as `(BVALID && BREADY) |-> ...`
would look at that moment, see both flags set, and **pass on a genuinely broken
design**. The evidence is gone by the time it looks.

The requirement is about the moment of *assertion*, so the check must be too.

## 4.4 The cover properties, and why one of them was worthless

A **cover property** is the opposite of an assertion: it does not check that
something never happens, it records that something *did* happen. It answers "did
my tests ever actually exercise this?"

The most important one is supposed to prove the driver sends `W` before `AW`
sometimes. As originally written:

```systemverilog
c_w_before_aw : cover property (w_acc ##[1:$] aw_acc);
```

`##[1:$]` means "some time later". So *any* W accept followed *eventually* by
*any* AW accept satisfies it — including the W of transaction 3 and the AW of
transaction 7. **It is satisfied by any multi-transaction run regardless of
ordering.**

The verification plan says this cover point exists to prove the driver is doing
something. It could not fail to be covered, so it could never warn about
anything. Fixed by qualifying it with the pending-flags so the match must fall
inside one transaction. The hit count on identical stimulus went from **10 to 1**
— nine of the ten were spurious.

That is BUG-007, and it is the first genuine bug the project found.

---

# Part 5 — The UVM testbench

UVM is a standard library for building testbenches. It gives you a component
hierarchy, a factory, phases and a configuration database, so that testbenches
across the industry look alike.

## 5.1 The pieces, and why each exists

```
uvm_test                       decides what to run
  axi_env                      holds everything
    axi_master_agent
      axi_sequencer            hands transactions to the driver
      axi_driver               turns a transaction into wire wiggles
      axi_monitor              watches the wires, rebuilds transactions
    axi_scoreboard             predicts what should happen, compares
    axi_coverage               records what was exercised
```

| Piece | Job | Why it is separate |
|---|---|---|
| **transaction** | one read or write as data | the unit everything else speaks about |
| **sequence** | decides which transactions | swapping the sequence changes the test |
| **driver** | drives pins | the only thing touching the master side |
| **monitor** | rebuilds transactions from pins | independent evidence |
| **scoreboard** | predicts and compares | the actual checking |
| **coverage** | records what was seen | what is still untested |

## 5.2 The four UVM mechanisms

**Phases** — every component runs its `build_phase` first (top-down, so a parent
can configure a child before it is built), then `connect_phase` (bottom-up, so
everything exists before ports are joined), then `run_phase` (the only one that
consumes simulated time).

**Objections** — `run_phase` ends when the last objection is dropped. Forget to
raise one and your test finishes at time zero, reports **passing**, and does
nothing. No error.

**config_db** — a global lookup so the driver can get the wire handle without
every layer between passing it down. It fails *silently* if the types do not
match, so every `get` is checked.

**Factory** — components are created by name (`type_id::create`) rather than by
`new()`, so a test can substitute a different type without editing the thing
that creates it. That is how sixteen planned tests share one environment
instead of sixteen copies that drift apart.

## 5.3 The driver, and the decision that shaped it

Almost every UVM tutorial drives one transaction to completion before starting
the next. **This driver cannot**, because AW and W are independent and a
lockstep driver could never produce W-before-AW.

So it runs **five threads**, one per channel, each pulling from its own queue:

```systemverilog
fork  aw_channel(); w_channel(); b_channel(); ar_channel(); r_channel();  join_none
```

`aw_delay` and `w_delay` are counted from the same instant, so their *relative*
values decide the ordering. Randomising two integers produces all three
orderings without a mode switch.

**Two semaphores, not one:**

```systemverilog
semaphore write_slot;   // released when B completes
semaphore read_slot;    // released when R completes
```

The spec permits one write *and* one read in flight at once. Two separate
permits is that rule expressed as objects. A read after a write proceeds
immediately; a second *write* waits.

**And `item_done()` fires on acceptance, not completion.** The sequence gets
control back as soon as a slot is claimed. This looks like a detail and is not:
`STATUS.busy` reads 1 only while a write is in flight, so observing it requires
a read *concurrent with* that write. Under the simpler scheme that concurrency
cannot happen and the feature becomes untestable.

## 5.4 The monitor, and the one line that would ruin it

The verification plan requires the monitor to be **fully passive** and rebuild
transactions from pins alone, sharing no state with the driver.

The tempting shortcut is one line: have the driver publish what it *intended* to
send. Do that and the scoreboard compares the driver against itself. A driver
sending the wrong address is checked against the wrong address and passes.
**Every driver bug goes invisible at once.**

So `axi_monitor` has no handle to the driver, no access to its queues, nothing
but the read-only wire view. It keeps its *own* accept-flags, duplicating logic
the driver and the hardware both also have — and the duplication is the point:
three independent answers to "when is a write complete" must agree.

How do we know it is genuinely independent? Three counts along paths that share
nothing:

```
issued 80 writes / 86 reads | monitor saw 80 / 86 | scoreboard got 80 / 86
```

If the monitor were echoing the driver, those would agree trivially and prove
nothing — which is why it has no route to the driver at all.

## 5.5 The scoreboard, and knowing what you cannot know

The scoreboard keeps its own model of the hardware, built **from the
specification**, and predicts every response and every read value.

The interesting part is what it *refuses* to predict:

```systemverilog
SB_COUNTER : mask = m_counter_zero ? 32'hFFFF_FFFF : 32'h0;
```

`COUNTER` increments every clock. The scoreboard sees *transactions*, not
cycles, so normally it cannot know the value — and it says so, counting the skip
and reporting it:

```
13 read-data checked, 1 skipped as unpredictable, 0 mismatches
```

**"Not checked" can never be mistaken for "checked and passed."**

The alternative would have been a tolerance — "within ±20" — which is how a
scoreboard quietly stops checking anything.

But "unpredictable" turned out to be too coarse. After `reset_stats` with
`enable` clear, `COUNTER` is 0 *and frozen there*, and every read must return
exactly 0. That one window is fully determined — and it is exactly where BUG-006
hides. Modelling it turned an always-skipped field into a check that catches a
planted bug.

---

# Part 6 — Everything that broke

Nine bugs. Six planted deliberately to prove the testbench works; three real.

## 6.1 Why plant bugs on purpose

A testbench that has never caught anything is unproven. You have no evidence it
would notice if the hardware were wrong — only that it is quiet, which is also
what a broken testbench looks like.

So the specification lists six defects to inject, each naming the mechanism that
must catch it. Injecting a bug and watching the *right* mechanism fire is the
only way to know that mechanism works.

Four of the six have been done. Two are blocked on components not yet built.

## 6.2 The planted ones

### BUG-002 — response before the data arrived

Made the slave answer as soon as the address arrived, ignoring the data.
`a_bvalid_not_early` fired at 335 ns.

**But the interesting result was a third experiment.** Running the same
injection three ways:

| Setup | Outcome |
|---|---|
| assertion bound | caught at the moment of violation, named the defect |
| no assertion, functional checks only | caught — but as *data corruption* 12 checks later |
| assertion bound, **AW-before-W stimulus removed** | **31 of 31 pass. Invisible.** |

The bug is only reachable when AW is accepted before W. Every other write in the
bench used same-cycle ordering. Remove that one stimulus and a bound, correct
assertion sits silently on a broken design.

**A checker constrains nothing if the stimulus never reaches the corner.** That
is the single most useful thing this project has learned, and it is why coverage
exists at all.

### BUG-003 — memory ignores the byte mask

Deleted the `if (wr_strb[b])` guard so every write hit all four bytes. The
scoreboard caught it with 6 mismatches — as §9 requires, because responses stay
OKAY throughout and no assertion could see it.

**And one check passed under the bug**, which is the more useful half:

```
PASS  WSTRB=1000 -> byte 3 only    0xaabbccdd
```

Memory held `0x00BBCCDD`; the write was `0xAABBCCDD` with only byte 3 enabled.
Correct behaviour and buggy behaviour give the *same answer*, because the data
already matched in the other three bytes. **A test can pass under a bug by
coincidence of data.** What discriminates is the cumulative sweep, where each
step leaves contents that differ from the next write.

### BUG-006 — the counter is not cleared

Removed the clearing branch. Detected by a directed test — and, once the
scoreboard learned about the frozen-at-zero window, by the reference model too.

The failure mode was **not** what the test comment claimed. The comment said an
uncleared counter "would be climbing here". It does not: the same write also
clears `enable`, so it **freezes at its uncleared value** — `0x15` on both reads.
The check fails either way, but the comment would have sent the next reader
hunting for the wrong symptom. Corrected in two files.

### BUG-001 — the driver breaks the protocol

The odd one: injected into the **testbench**, not the hardware. `AWVALID` is
driven by the master, so no slave defect can violate its stability. This bug
qualifies the *checker*; BUG-002 qualifies its ability to catch a *design*
defect. Same family of assertion, two different things proven.

`a_awvalid_stable` fired three times. And then:

```
all 5 checks passed
UVM_ERROR : 0
```

**The bus was driven illegally on every write, every functional check passed,
and UVM reported zero errors.** The slave tolerates the malformed handshake and
returns correct data, so reading back what you wrote proves the *data path*
works and says nothing about whether the *protocol* was obeyed.

Functional correctness and protocol compliance are independent properties. That
run separates them cleanly, and it is the argument for binding a protocol
checker stated as a measurement rather than an opinion.

It also left a trap for later: SVA failures do **not** appear under
`Report counts by severity`. A regression script keying on `UVM_ERROR : 0` would
score that run as a pass. Only the exit code disagrees. Written down before the
regression runner exists.

## 6.3 The real ones — all four in the testbench

### BUG-007 — a cover point that could not fail

Described in Part 4.4. The cover property meant to prove driver independence was
satisfied by any multi-transaction run. Hit count fell **10 → 1** on identical
stimulus once qualified.

The risk was never that it stayed uncovered. It is that it *could not* stay
uncovered, so it could never warn.

### BUG-008 — an assertion that failed on correct hardware

Found by random traffic on its first run.

```systemverilog
(aw_acc && AWADDR[1:0] != 0) |-> ##[1:8] (BVALID && BRESP != 0)
```

It starts a timer at the address accept and demands a response within eight
cycles. But the response cannot come until the *data* is also accepted, and that
gap belongs to the **master** — bounded by nothing in the spec. Randomised
delays go to 20.

The scoreboard said the design was fine; the assertion said it was not. Only
reasoning from the specification separates them. **Had the environment contained
only the assertion, the obvious next move would have been to "fix" correct
hardware.**

A false alarm is the worse failure. A missed detection leaves a bug in the
design; a false detection gets the checker muted, and then it is worthless on
the day it is right.

Fixed by checking at the response with no window: *at every response, either the
address was aligned or the response is an error.*

**Every directed test used delays of 4 or less.** 44 UVM checks and 58 non-UVM
checks never went near it. 150 random transactions hit it twice.

### BUG-009 — a race that passed for eleven days

The memory test hung. The simulator was killed with exit 137 and no message — a
hang was the one failure this environment could not report. So the first fix was
a watchdog, which printed something that looked impossible:

```
AW  VALID=0 READY=1  ADDR=0x00001000
W   VALID=0 READY=1  DATA=0xcafebabe STRB=1111
```

The payload was driven but `VALID` was low. That cannot happen from a single
sequence of statements — which meant the fault was in my understanding of the
code, not in the hardware.

A clocking-block assignment takes effect at the *next* clock event. The channel
thread woke at whatever moment the sequencer handed it work — not necessarily
on a clock edge — and with a zero delay nothing re-aligned it. The assert and
the de-assert then landed on the *same* clock event, and the later one won:

```
AWVALID <= 1'b1;                  -> event E
do @(cb); while (!AWREADY);       -> returns at E
AWVALID <= 1'b0;                  -> also E, and wins
```

The address is written once so it survives. `AWVALID` is written twice so it
never rises.

**It had been passing for eleven days.** 44 directed checks and 166 random
transactions, all on timing luck — whether the race bites depends on when the
handshake lands relative to the clock, and on the first design it always landed
safely.

Two things worth keeping from it:

- **Randomising the payload does not randomise the timing** of when a sequence
  hands work to a driver. Random data found BUG-008; only a different design
  shifted the schedule enough to find this.
- The non-UVM benches never had the bug — every task there starts by waiting for
  a clock edge. The UVM driver was written from design notes rather than from
  the working bench, and that alignment was dropped without anyone noticing it
  was load-bearing.

## 6.4 The pattern

**All three genuine finds are in the testbench, not the design.** The
environment has found more defects in itself than in the thing it is checking.

That is not a flattering sentence and it is the true one. The hardware was
written from a specification that had been corrected first, and it is small. The
testbench is four times larger, was written under time pressure, and had no
second party checking it — except itself.

None of the three was a missed detection. Each was **false confidence** of a
different kind: a metric that could not fail, a checker that cried wolf, and a
test suite passing on luck.

---

# Part 7 — Everything that was still missing, and how it got built

Parts 0–6 describe the project as it stood with two slaves, an agent, a
scoreboard and a coverage model. Three things were unbuilt, and each blocked a
named list of others.

## 7.1 The interconnect

**Blocked:** `DECERR`, three `cg_address_region` bins, F17, F18, BUG-005, and any
test that touches both slaves at once.

The interesting part is not the mux. It is the address map:

```
0x0000_0000 .. 0x0000_0FFF   registers
0x0000_1000 .. 0x0000_13FF   memory
0x0000_1400 and above        unmapped -> DECERR
```

`ADDR[12]` alone routes `0x1400` to memory. So does `ADDR[13]`. Both are the
obvious implementation and both are wrong — and the gap exists in the
specification *precisely so that they are*. §7 says so, and §9 makes "decodes on
`ADDR[13]` alone" an injection.

The genuinely hard part is §7's other sentence: **W can arrive before AW, and
then the destination is unknown.** A slave can accept a W beat early because it
has only one place to put it. An interconnect cannot — until AW arrives it does
not know which slave the beat belongs to, and forwarding it to a guess is
unrecoverable. So the beat is *held*, in a buffer that is provably one entry deep
because §1 caps outstanding writes at one.

It worked on the first run: 36 of 36 checks, and no assertion fired from any of
the three bound checker instances.

**What it changed about the coverage story.** Until it existed, every address the
master issued was answered by the one slave in the design, so `cg_address_region`
recorded the address *issued* rather than the traffic *routed*. The old
`coverage_status.md` spent three paragraphs refusing to report that as a green
metric. Those paragraphs are now spent, which is the right way for a
justification to end.

## 7.2 The RAL, generated rather than written

**Blocked:** F10–F13 and BUG-004.

`scripts/regmap.yaml` is the register map, once. It generates three things: the
RTL's parameter package, the UVM RAL model, and `register_map.md`. A fourth
script checks it against §5 of the specification, which remains the source of
truth.

The point is not saved typing. It is that `uvm_reg_bit_bash_seq` — library code
that has never read this project's spec — checks the DUT against a policy stated
in one place. When `INT_STATUS` was injected as a plain RW register, `bit_bash`
caught it **with nobody having written a test for it**.

What is deliberately *not* generated: the register slave's behaviour. W1C
set-beats-clear, `CTRL[1]`'s self-clearing pulse, `STATUS.error`'s transparency
rule and `COUNTER`'s priority are one spec paragraph each, and an `always_ff`
that cites the paragraph is a better expression of them than any template.

Also not generated: **the scoreboard**. A reference model sharing constants with
the design agrees with the design by construction — which is what BUG-007 was.

## 7.3 The flow

**Blocked:** everything, once there is more than one test.

Six tools, and the one that mattered most was not in the plan.

### The round trip was the real constraint

UVM cannot be simulated locally. Icarus and Verilator have no UVM support, so the
only simulator that runs this environment is Xcelium on EDA Playground — reached
by clearing two panes and pasting into a browser. Writing thirteen tests, a RAL
and an interconnect against that loop meant dozens of manual cycles, most of them
spent on typos.

**slang** fixed it. It cannot simulate; it *elaborates*, and elaboration is where
typos live. It checks the generated bundle byte for byte — the same file that
gets pasted — in about a fifth of a second.

Pointed at the existing, working sources it immediately rejected two constraints:

```
error: invalid operands to binary expression ('bit' and 'void')
    soft (kind == AXI_WRITE) -> strb dist {
```

`soft (a) -> b dist {...}` selects the wrong production of IEEE 1800-2017's
constraint grammar. Xcelium accepts it. Every number this project had published
came through it. That is [BUG-010](bug_reports/BUG-010.md), and the lesson
generalises past the bug: **a testbench validated by exactly one simulator has
been validated against that simulator's extensions as much as against the
language.**

### Three pastes instead of twenty-four

Everything else about the flow follows from minimising the manual step:

- the thirteen directed scenarios are **sequences** with thin test wrappers, so
  all fifteen run inside one simulation;
- the seed arrives as a **define**, because Playground's command line is fixed
  and cannot pass `+SVSEED`;
- eight random seeds run inside a single job, because Playground cannot launch
  eight jobs either.

### The toolkit found three defects in the flow it automates

Which is the argument for building it. The regression runner's first real use
reported five of ten seeds `INCOMPLETE` — ten parallel runs of one top were
building into the same directory, each starting with `rm -rf`. Splitting build
from run fixed it and took the regression from 90 seconds to 11.

---

# Part 8 — The formal experiment, and the result that justifies it

Specification §5 states a rule:

> **Set-vs-clear collision:** if an event sets `INT_STATUS` bit *n* on the same
> cycle a write would clear it, **set wins**. The event is real and must not be
> lost.

It is a **same-cycle** rule. A transaction-level sequence sees transactions, not
clock edges, and cannot place an event and a W1C write on one edge on purpose.
`axi_int_status_seq` says exactly that in the file, proves the reachable half, and
declines to claim the rest.

So the priority was inverted in the RTL — an interrupt-losing defect — and both
flows were run against it:

| | Verdict on a design that loses interrupts |
|---|---|
| Simulation: 3 directed benches, 5 random seeds, **4,576 checks**, 23 bound assertions | **all passed** |
| Bounded model check, 16 properties, depth 25 | **failed in under a second**, naming `f_set_beats_clear_0` |

**That is the strongest single result in this repository, and it is a negative
one.** Not "formal is rigorous" in the abstract: one rule in this specification,
which this testbench cannot reach by construction, decided immediately.

The reason simulation cannot reach it is structural rather than a stimulus gap.
The scoreboard compares before-and-after values across a whole transaction, and
the collision happens inside one. More seeds do not help. A directed test does
not help. The check has to be about a clock edge, and only one of the two flows
works in those units.

## 8.1 The half people skip

An assertion that is never reached passes trivially, and a set of them will all
pass on a design that does nothing. So every run also proves the interesting
states are **reachable**:

```
Reached cover statement in step 3: fc_collision
```

`fc_collision` is the same-cycle event-and-clear itself. Without it,
`f_set_beats_clear_*` could be passing because nothing can ever produce the
collision — and the whole file would be decoration.

## 8.2 What the tool could not do, which is also a finding

Yosys's open-source frontend supports **no concurrent SVA at all**. `default
clocking`, `|=>`, `property … endproperty`, in-module `import`, hierarchical
references and `bind` were each tried and each rejected, with the exact error
recorded in [formal_notes.md](formal_notes.md).

That is the same kind of finding as *"Riviera compiles UVM and cannot simulate
it"* — a measured tool limit that changed the design of the work, written down so
the next person does not spend the afternoon rediscovering it.

---

# Part 9 — The AI layer, measured

The automation plan set the terms before anything was built:

> *Every student will say "I used AI." … Claiming without measuring is how you
> lose the conversation. Unmeasured, it's the weakest thing in your repo.
> Measured, it's among the strongest.*

Fed a failure signature and a log excerpt — and nothing else — a model named the
actual root cause of **4 of the 6** injected bugs, got the right component with
the wrong mechanism on the other 2, and was never wrong in a way that would have
sent someone to the wrong file.

## 9.1 Two measurements before that one were invalid

Both are published, because a number produced by a broken harness is worse than
no number: it looks like rigour.

**The model could read the repository.** The first run scored 5/6 — and its
BUG-005 answer cited `rtl/axi4lite_interconnect.sv:152`. That is not triage, it
is looking up the answer, and the score measured file access rather than
inference. The backend is now sealed: an empty working directory, every file and
execution tool disallowed.

**The scorer graded the whole answer.** Sealed, it still said 5/6 where a hand
review said 4/6. The disagreement was BUG-005: its *root cause* was wrong, and it
scored `correct` because the phrase "bit-sliced compare" appeared in its *next
step*. A next step is a suggestion; a root cause is a claim, and only the claim is
what the tool is measured on.

Mechanical and hand review now agree at 4/6.

---

# Part 10 — What is actually proven

## 10.1 Verified by a run

- Two slaves and an interconnect, against a reference model derived from the
  specification and fed by a monitor that reconstructs from pins.
- 23 SVA assertions on three ports — the interconnect checked as a slave from the
  master's side and as a master from each slave's side.
- 29 of 29 features traced to a test, generated from the specification's own
  feature list so an unclaimed feature would appear as `UNCOVERED`.
- 14 of 14 cover properties non-zero, five of which had never left zero.
- 16 formal properties, with a cover pass proving none is vacuous.
- Six injected defects, each caught by the mechanism §9 assigned it in advance.

## 10.2 The limits, stated

- **Two features are reachable only in UVM**: `STATUS.busy`, which needs a read
  concurrent with an in-flight write, and `COUNTER` overflow, which needs 65,536
  cycles. Both run on Xcelium, by hand.
- **Some cover points are zero and must stay zero.** `DECERR` at a slave port
  would be a defect, not coverage. Which zeros are structural is written out
  rather than left to be "closed" later by stimulus that cannot reach them.
- **The formal proof is bounded**, at 25 and 40 cycles, over one slave's internal
  state. Not an unbounded proof, not the interconnect, no liveness.
- **Tool coverage is inert on the free simulator.** Covergroups report `0.00%`
  because collection cannot be enabled from a fixed command line, so every bin is
  *also* counted by hand — which no tool switch can disable, and which reports
  missing bins by name rather than only a percentage.

## 10.3 The six sentences worth having ready

1. *"I found two contradictions in my own frozen specification while deriving the
   architecture on paper, fixed the document first, and every revision now has a
   test that fails under the old wording."*

2. *"My cover point was passing for the wrong reason — it could not fail to be
   covered. Qualifying it dropped the hit count from ten to one on identical
   stimulus."*

3. *"I broke my own design to prove the checker caught it — and the third
   experiment mattered most: with the stimulus removed, a correct, bound
   assertion sat silently on a broken design and 31 of 31 checks passed."*

4. *"I injected a protocol violation into my driver. Every functional check passed
   and UVM reported zero errors. Only the assertion saw it."*

5. *"My testbench had only ever been read by one simulator, so it had been
   validated against that simulator's extensions as much as against the language.
   A second, conformant front end found two malformed constraints in 0.2 seconds
   — in code that had been producing published numbers for three weeks."*

6. *"There is a rule in my specification that no test I can write is able to
   decide, and I can show you why: 4,576 simulation checks pass on a design that
   violates it, and a bounded model check finds it in under a second."*

Each of those is a measurement, not a claim. Four of them are about something
being wrong.
