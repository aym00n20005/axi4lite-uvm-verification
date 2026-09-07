# Functional coverage — status and justifications

**This file is written by hand.** The measured numbers are generated into
[coverage_report.md](coverage_report.md) by `make coverage`; this one carries the
part a generator cannot supply.

Verification plan §5 sets the closure criterion: 100% on all groups except
`cg_wstrb` at ≥90%, and **every uncovered bin must be individually justified in
writing**. "We ran out of time" is not a justification. This is that record.

---

## What changed, and what it cost to change it

The August version of this file justified four open bins with a single cause:

> There is no interconnect, so no address decode exists to route a transaction to
> the memory slave or to terminate an unmapped one. **This is structural, not a
> stimulus gap.** … Not reachable before then by any amount of stimulus.

That was correct, and it is now spent. `rtl/axi4lite_interconnect.sv` exists,
`REGION_MEM`, `REGION_UNMAPPED_LOW`, `REGION_UNMAPPED_HIGH` and `cg_response`'s
`DECERR` bin are all reachable, and `cg_address_region` now records traffic
**routed** rather than addresses merely **issued** — which is the distinction the
old file spent three paragraphs refusing to gloss over.

Three groups that the August file listed as *not modelled* — `cg_valid_delay`,
`cg_backpressure`, `cg_reset` — are modelled. Its stated blocker was that they
"need per-cycle timing the monitor does not record", and it named the fix:
`cg_aw_w_order` had left that list when the monitor began timestamping accepts,
and "the same treatment extends to the other three". It did.

**All eleven groups in vplan §5 are now modelled, plus all four crosses.**

## Cover properties — closed, locally

Fourteen of fourteen are non-zero. Five of them read 0 in *every run this project
made* until the interconnect and the seeded random bench existed:

| Cover point | Before | Now (master port) | What closed it |
|---|---|---|---|
| `c_b2b_write` | 0 | **650** | `sanity_rand_tb` — per-channel engines that keep the next transaction's VALID asserted while the current one completes |
| `c_b2b_read` | 0 | **633** | same |
| `c_write_backpressure` | 0 | **2793** | same, plus holding READY low *after* VALID rises rather than before |
| `c_read_backpressure` | 0 | **2475** | same |
| `c_resp_decerr` | 0 | **195** | the interconnect existing at all |

All five closed **under Verilator**, with no commercial simulator involved.

The four in the first group were never a stimulus *volume* problem. A sequential
driver — drive AW, drive W, wait for B, repeat — cannot produce a back-to-back
accept or three consecutive cycles of `AWVALID` with `AWREADY` low, however many
transactions it runs. It needed a different *shape* of driver.

## Zeros that are correct, and must stay zero

These are the ones most at risk of being "closed" by someone adding stimulus that
cannot reach them, so they are written down as structural.

| Cover point | Zero at | Why it is correct |
|---|---|---|
| `c_resp_decerr` | both slave ports | Spec §4: `DECERR` is produced by the interconnect and never by a slave. Neither slave defines `2'b11`. A non-zero here would be a **defect**, not coverage |
| `c_w_before_aw`, `c_aw_before_w` | both slave ports | The interconnect forwards AW and W **together**, so a slave always accepts them in the same cycle. W-before-AW is a property of the master port, and the interconnect absorbing it is what holding the beat *means* |
| `c_b2b_write`, `c_b2b_read` | both slave ports | The interconnect inserts response states between transactions, so it never issues back-to-back to a slave |
| `c_write_backpressure`, `c_read_backpressure` | both slave ports | The interconnect raises its own `BREADY`/`RREADY` the cycle a slave responds, so it never stalls one |

Four of those five rows are consequences of one design decision, recorded in
[interconnect_architecture.md §4](interconnect_architecture.md).

## Functional coverage — measured on Xcelium

The hand tally from the four EDA Playground runs, all four of them clean.
`axi_multiseed_test` closes the model broadly; the directed tests are narrower by
design and their gaps are all attributable to what each one does not do.

| Group | `multiseed` | `protocol` | `register` | `ral` | Union | Goal |
|---|---|---|---|---|---|---|
| `cg_transaction_type` | **2/2** | **2/2** | **2/2** | **2/2** | **2/2** | 100% |
| `cg_address_region` | **5/5** | **5/5** | 3/5 | 2/5 | **5/5** | 100% |
| `cg_register_offset` | **8/8** | **8/8** | 5/8 | **8/8** | **8/8** | 100% |
| `cg_alignment` | **4/4** | **4/4** | **4/4** | 1/4 | **4/4** | 100% |
| `cg_wstrb` | **16/16** | **16/16** | 8/16 | 1/16 | **16/16** | ≥90% |
| `cg_response` | **3/3** | **3/3** | **3/3** | 2/3 | **3/3** | 100% |
| `cg_error_source` | **4/4** | **4/4** | **4/4** | 2/4 | **4/4** | 100% |
| `cg_aw_w_order` | **3/3** | **3/3** | **3/3** | **3/3** | **3/3** | 100% |
| `cg_valid_delay` | 3/4 | 2/4 | 2/4 | 2/4 | 3/4 † | 100% |
| `cg_backpressure` | **4/4** | **4/4** | **4/4** | **4/4** | **4/4** | 100% |
| `cg_reset` | 0/3 | **3/3** | 0/3 | 0/3 | **3/3** | 100% |

**Ten of the eleven groups reach 100%, and the eleventh is at its structural
maximum.** † `cg_valid_delay`'s `d0` bin cannot be produced by this driver at
all — the reasoning is below, and it is a property of the driver's shape rather
than a stimulus gap.

Every bin that this environment can hit, it hits.

### `cg_reset` — closed, and it took two defects to get there

This group read **0/3 in every run this project had ever produced** until the
last one. It now reads 3/3, and the path to it is worth recording because
nothing about it was a stimulus problem.

`axi_reset_seq` was written to hit all three bins and had been in the tree for
some time. What stopped it:

1. `aw_delay == 25` against a hard constraint of `[0:20]`. The `randomize()`
   failed, the transaction completed before reset arrived, and `RESET_IDLE` was
   the only bin reachable. The test *passed its own checks* while doing this.
2. With that fixed, the mid-write case finally reset a transaction that was
   genuinely in flight — and hung, because nothing retired it
   ([BUG-014](bug_reports/BUG-014.md)). The watchdog killed the run at 40 µs.

Only after both were fixed did the sequence do what it was written to do:

```
[axi_monitor] RESET low 5 cycles                             -> RESET_IDLE
[axi_monitor] RESET low 5 cycles during a WRITE              -> RESET_MID_WRITE
[axi_monitor] RESET low 5 cycles                during a READ -> RESET_MID_READ
```

**A zero in a coverage table is not always a missing test.** Here the test
existed, ran, and reported all-pass for two runs while covering a third of what
it claimed. The bin is what noticed.

The accounting confirms it end to end:

```
sequences issued 128/111 | driver dispatched 128/111 (1/1 abandoned by reset)
                         | monitor saw 127/110 | scoreboard got 127/110
```

One write and one read abandoned, so the monitor sees exactly one fewer of each.
That line is the reason the count check exists.

### `cg_valid_delay` — the `d0` bin is unreachable by construction

`d0` counts a request channel whose idle gap before `VALID` rose was **exactly
zero cycles**. The driver cannot produce it. Each channel task deasserts `VALID`
after its accept and re-asserts at the next clocking event, so there is always at
least one idle cycle between transactions — even in `axi_b2b_seq`, where the gap
between *accepts* is zero but the gap between `VALID` assertions is not.

This is structural, not a stimulus gap, and it is a consequence of the driver
shape the project chose deliberately: per-channel threads that each own their
`VALID` for exactly the span of one transaction. A driver that held `VALID` high
across back-to-back transactions would close the bin and would also be unable to
express a per-transaction delay at all.

**The measurement is still the right one.** `d1_3`, `d4_10` and `d_over` are all
hit by `axi_multiseed_test`, so the group distinguishes short gaps from long
ones, which is what F28 and the delay distribution are about. What it cannot
distinguish is zero from one.

The directed tests sit at 2/4 because their delays come from a narrow
distribution, not because they are missing anything: `d1_3` needs a one-to-three
cycle gap, and the directed sequences mostly use either 0 (which lands in the
same observed bin as 1) or their own larger, deliberate delays. The random
bundle is what spreads them, which is what it is for.

## The groups and their goals

Full per-run tables are in [coverage_report.md](coverage_report.md), regenerated
by `make coverage`. Goals:

| Group | Goal | Modelled since |
|---|---|---|
| `cg_transaction_type` | 100% | 21 Aug |
| `cg_address_region` | 100% | 21 Aug — **meaningful** since the interconnect |
| `cg_register_offset` | 100% | 21 Aug |
| `cg_alignment` | 100% | 21 Aug |
| `cg_wstrb` | ≥90% | 21 Aug |
| `cg_response` | 100% | 21 Aug — `DECERR` reachable since the interconnect |
| `cg_error_source` | 100% | 21 Aug |
| `cg_aw_w_order` | 100% | 21 Aug |
| `cg_valid_delay` | 100% | **6 Sep** |
| `cg_backpressure` | 100% | **6 Sep** |
| `cg_reset` | 100% | **6 Sep** |
| crosses ×4 | 100% | 21 Aug ×3, **6 Sep** ×1 (`type × backpressure`) |

### The three new groups measure the DUT's experience, not the driver's knobs

This is the same principle the collector was built on and it is worth restating,
because the easy implementation of each of these would have violated it:

- **`cg_valid_delay`** samples the idle gap a request channel showed before VALID
  rose — **not** `aw_delay`. `aw_delay` is counted from dispatch, an instant no
  pin shows and the DUT does not experience. The gap between transactions is what
  a slave actually sees.
- **`cg_backpressure`** counts cycles a response spent asserted with the master's
  READY low, from the monitor's own observation.
- **`cg_reset`** answers "was anything in flight when `ARESETn` fell?" from the
  **monitor's own accept queues**. The driver is not asked.

Sampling the stimulus fields instead would measure the testbench's intentions
rather than the DUT's experience, which is the failure `axi_coverage` exists to
avoid — and, in its inverted form, the failure [BUG-007](bug_reports/BUG-007.md)
was.

## Two mechanisms, and why

Unchanged, and still true: every bin is counted twice, by a SystemVerilog
covergroup and by a hand tally in an associative array.

The covergroups are the real artifact. They are also **inert on EDA
Playground**: Xcelium requires coverage enabled at elaboration
(`-coverage functional`), Playground's command line is fixed and cannot pass it,
and the result is not an error but a silent `0.00%`:

```
*N,COVNSM: Sampling of covergroup type "axi_coverage::cg_transaction_type"
is not enabled. As a result, get_inst_coverage() will return 0 coverage.
```

Xcelium says so explicitly; a quieter tool would have shown zero and left the
project believing coverage was genuinely zero. The hand tally cannot be disabled
by a tool switch, and it reports **missing bins by name** rather than only a
percentage — `cg_wstrb 12.50%` says how far there is to go, `missing: 0000 0001
0010 …` says what to write.

That distinction is what closed three groups on 21 August: the first measurement
named `INT_ENABLE`, `offset_1`, `offset_3` and fourteen strobe patterns, and all
of them turned out to be transactions nobody had written rather than anything
about the design.

## How long a bin has been at zero

`make coverage` appends to `results/coverage_history.json` and flags any cover
point that has been zero across consecutive runs. That table says *how long*;
this file says *which kind* — a stimulus gap somebody should close, or a
structural fact somebody should write down. Only a person can make that call, and
the history is what stops it from being made twice.
