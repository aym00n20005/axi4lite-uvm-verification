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

## Functional coverage — the UVM groups

Measured numbers are in [coverage_report.md](coverage_report.md), regenerated
from an imported EDA Playground log by `make coverage`. Groups and their goals:

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
