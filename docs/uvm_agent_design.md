# UVM Agent — Architecture

**19 August 2026 · precedes `tb/agent/`**

Same discipline as `reg_slave_architecture.md`: decide on paper, then write it.
Two decisions here shape every component that follows, and both are easier to
get right now than to retrofit on the 27th.

---

## 1. One transaction, three channels

A write is `AW + W + B`. A read is `AR + R`. But `axi_transaction` is **one
object**, not three, because the thing the scoreboard reasons about is a
transaction, not a channel beat.

That means the driver takes one object and hands *different fields of it to
different threads*:

| Thread | Reads from the transaction |
|---|---|
| AW | `addr`, `aw_delay` |
| W | `data`, `strb`, `w_delay` |
| B | writes back `resp` |
| AR | `addr`, `ar_delay` |
| R | writes back `data`, `resp` |

The delay fields are what make ordering controllable. `aw_delay` and `w_delay`
are measured from the same instant — the moment the driver accepts the
transaction — so their *relative* values decide the ordering:

```
aw_delay <  w_delay   ->  AW first
aw_delay >  w_delay   ->  W first
aw_delay == w_delay   ->  same cycle
```

That is `cg_aw_w_order`'s three bins falling directly out of two random
integers, and it is why F03 is reachable from constrained-random stimulus
rather than needing three directed tests.

## 2. When does `item_done()` fire?

The decision flagged on the 21st. Two candidates:

**(a) On completion** — the driver calls `item_done()` after the B or R
handshake. Simple, and the sequencer naturally throttles to one outstanding
transaction.

**(b) On acceptance** — `item_done()` once the channel threads own the
transaction. The driver itself enforces the outstanding limit.

**Chosen: (b), on acceptance.** Option (a) is simpler but wrong for this DUT,
and the reason is a specific feature in the plan.

Spec §1 permits **one write and one read in flight simultaneously**. Under (a),
a sequence issuing write-then-read cannot have both in flight: the read waits
for the write's B response. Everything downstream of that loses:

- **F24 (`STATUS.busy`) becomes untestable.** The bit reads 1 only while a write
  is in flight, and observing it requires a read *concurrent with that write*.
  Under (a) that concurrency cannot occur, so the coverage bin never closes —
  and this is the same testability trap the spec already avoided once, when it
  restricted `busy` to the write path (§5).
- `c_b2b_write` and `c_b2b_read` get harder, because every transaction is
  separated by a full response round-trip.
- The single-outstanding *check* becomes vacuous. `a_single_outstanding_write`
  can only catch a DUT that accepts too much if the driver is capable of
  offering too much.

That last point is the general one, and it is the same lesson as BUG-002: **a
checker constrains nothing if the stimulus cannot reach the corner.** A driver
that self-throttles to one transaction can never test whether the DUT enforces
its own limit.

**Consequence:** the driver owns two independent slots, one write and one read,
each held from acceptance until its response completes. `item_done()` fires as
soon as the relevant slot is claimed. A second write blocks; a read alongside a
write does not.

## 3. Response fields are not `rand`

`resp` — and `data` on a read — are filled in by the driver from the B and R
channels, and independently by the monitor from the pins. They are declared
outside the `rand` set and excluded from comparison, because randomising a
field the DUT is supposed to produce is how a scoreboard ends up checking the
testbench against itself.

## 4. Address regions are a first-class field

`region` is a random enum constrained to pick the address, rather than the
address being randomised freely and the region inferred afterwards.

```systemverilog
rand axi_region_e region;
rand bit [31:0]   addr;
constraint c_region_addr { region == REGION_MEM -> addr inside {[32'h1000:32'h13FF]}; }
```

Two reasons. Randomising `addr` across the full 32-bit space would land in
`REGION_UNMAPPED_HIGH` essentially every time — the mapped regions are five
kilobytes out of four gigabytes. And the enum's five values are exactly
`cg_address_region`'s five bins, so coverage sampling is `region` rather than a
second, separately-maintained address decode that can drift out of step with
the first.

The same argument applies to `misaligned`: a random 32-bit address is aligned
one time in four by luck, which is neither a useful distribution nor a
controllable one.

## 5. What is not built yet

`axi_sequencer` is a typedef and nothing more. It is named explicitly rather
than using `uvm_sequencer #(axi_transaction)` inline so that if it ever needs
arbitration or a lock/grant policy, there is a place to put it.

The driver (23–24 Aug) and monitor (25 Aug) are next. Until the driver exists,
the transaction is exercised by `axi_rand_smoke` — randomising several hundred
transactions and tallying the distributions — which validates the constraints
*before* anything depends on them.

---

## 6. Measured stimulus distribution

Run `make playground PLAY=rand_smoke`, paste into EDA Playground, Xcelium,
UVM 1.2. 500 items, `SVSEED default: 1`.

**19 August 2026 — after rebalancing.** 0 errors, 0 warnings; every
`require_bin` satisfied.

| Group | Bins (n) |
|---|---|
| kind | READ 50.6%, WRITE 49.4% (n=500) |
| `cg_address_region` | MEM 42.6%, REG_IMPL 41.6%, UNMAPPED_HIGH 6.4%, REG_UNIMPL 4.8%, UNMAPPED_LOW 4.6% (n=500) |
| `cg_aw_w_order` | AW_FIRST 41.7%, W_FIRST 41.3%, SAME_CYCLE 17.0% (n=247, writes only) |
| `cg_wstrb` | full 26.4%, partial 18.0%, zero 5.0%, n/a-read 50.6% (n=500) |
| `cg_valid_delay` (aw) | 0 → 35.0%, 1–3 → 35.0%, 4–10 → 20.6%, >10 → 9.4% |
| `cg_backpressure` (b) | 0 → 42.6%, 1–3 → 33.4%, 4–10 → 13.8%, >10 → 10.2% |
| misaligned | 9.4% |
| **expects error** | **30.8%** |

### What the first run changed

The initial weights produced **48.8%** error traffic. That is wrong for
`axi_random_test`, whose purpose is F01/F02/F14/F28 — the *working* data paths.
At half errors it barely reaches a register or a memory word. The error paths
belong to the directed tests, which raise the weights themselves.

Three changes brought it to 30.8%: region weights shifted toward the mapped
regions, misalignment from 15% to 8%, and one correlation added —

```systemverilog
soft (kind == AXI_WRITE && region == REGION_REG_IMPL) ->
    strb dist { 4'b1111 := 80, [4'b0000 : 4'b1110] :/ 20 };
```

A partial-strobe write is an error on the register slave (F16) and the normal
case on memory (F15). Uncorrelated, F16 alone was ~8% of all stimulus.

### Why the constraints are `soft`

Every distribution constraint carries `soft`. A sequence can then write

```systemverilog
t.randomize() with { region == REGION_MEM; };
```

and the soft weight yields rather than producing a contradiction. Without it,
each of the sixteen tests in the plan would need its own transaction subclass —
the same drift problem the factory solves for components, one level down.

`axi_rand_smoke` warns above 35% error traffic rather than erroring, because a
directed test is entitled to push it to 100%. The guard catches accidental
drift in the defaults, not deliberate steering.

### Known cosmetic gap

`cg_wstrb` currently tallies reads into an `n/a (read)` bin, so its percentages
are against all items rather than writes. Harmless in the smoke test, and it
disappears in October: the real covergroup samples on write transactions, so
reads never enter it.
