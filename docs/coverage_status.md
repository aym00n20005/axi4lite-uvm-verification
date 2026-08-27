# Functional Coverage — status and justifications

**21 August 2026.** Measured by `axi_smoke_test` on Cadence Xcelium 25.03,
UVM 1.2. 44 transactions observed. Reproduce with `make playground PLAY=smoke`.

Verification plan section 5 sets the closure criterion: 100% on all groups
except `cg_wstrb` at >=90%, and **every uncovered bin must be individually
justified in writing**. "We ran out of time" is not a justification. This file
is that record.

---

## Measured

| Group | Bins | Goal | Status |
|---|---|---|---|
| `cg_transaction_type` | 2/2 | 100% | ✅ |
| `cg_register_offset` | 8/8 | 100% | ✅ |
| `cg_alignment` | 4/4 | 100% | ✅ |
| `cg_wstrb` | **16/16** | ≥90% | ✅ exceeds goal |
| `cg_error_source` | 4/4 | 100% | ✅ |
| `cg_aw_w_order` | 3/3 | 100% | ✅ |
| `cg_address_region` | 2/5 | 100% | ❌ justified below |
| `cg_response` | 2/3 | 100% | ❌ justified below |

## Justification for every uncovered bin

Two groups, three bins, **one cause**.

### `cg_address_region` — all five bins hit, and that is misleading

**Updated 23 August.** `axi_random_test` drives addresses across the whole map,
so all five bins now report covered. **This does not mean those regions are
verified**, and the number should not be read as if it did.

The coverage model classifies by the address the master issued, which is what
vplan §5 asks for. But `tb_top` instantiates only the register slave, so a
transaction to `0x1078` is not routed to memory — it aliases onto the register
slave's `ADDR[11:0]` decode and is answered, correctly, as register traffic. The
bin records that an address in the memory range was *issued*, not that the
memory slave *served* it.

A green `cg_address_region` while the memory slave is absent from the DUT is
exactly the failure mode BUG-007 was: a metric that cannot fail to look good.
The honest statement is below, and it is unchanged by the random run.

### `REGION_MEM`, `REGION_UNMAPPED_LOW`, `REGION_UNMAPPED_HIGH` — not routed

`tb/tests/tb_top.sv` instantiates `axi4lite_reg_slave` and nothing else. There
is no interconnect, so no address decode exists to route a transaction to the
memory slave or to terminate an unmapped one. Every address the UVM environment
issues is seen by the register slave, which decodes `ADDR[11:0]` and therefore
classifies all of them as register-region traffic.

This is **structural, not a stimulus gap**. Issuing a transaction to `0x1000`
today would not reach the memory slave; it would alias onto `CTRL` inside the
register slave, exactly as `0x100` aliases onto `CTRL` — routing is the
interconnect's responsibility, and the register slave is behaving correctly.

**Closes:** September, with `rtl/axi4lite_interconnect.sv` (vplan milestone
30 Sep). Not reachable before then by any amount of stimulus.

### `cg_response` — `DECERR`

Same cause, stated separately because the bin is in a different group. Spec
section 4: `DECERR` is produced by the **interconnect** for an unmapped address
and never by a slave. Neither slave contains a code path that can emit `2'b11`,
by design — `axi4lite_reg_slave` and `axi4lite_mem_slave` both define only
`RESP_OKAY` and `RESP_SLVERR`.

A `DECERR` in the current testbench would be a defect, not coverage.

**Closes:** September, with the interconnect.

## Groups not modelled yet

Declared in vplan section 5, deliberately absent from `axi_coverage` rather
than faked:

| Group | Why not |
|---|---|
| `cg_valid_delay` | needs per-cycle VALID timing; the monitor records transactions, not cycles |
| `cg_backpressure` | needs per-cycle READY timing, same reason |
| `cg_reset` | needs reset events; the monitor does not watch `ARESETn` |

All three require the monitor to record cycle-level timing it currently
discards. `cg_aw_w_order` was in this category until 21 August, when the monitor
began timestamping the AW and W accepts — the same treatment extends to the
other three and is the obvious next step.

Sampling them from the stimulus fields instead would be measuring the
testbench's intentions rather than the DUT's experience, which is the failure
`axi_coverage` exists to avoid.

## Two mechanisms, and why

Every bin is counted twice: by a SystemVerilog covergroup, and by a hand tally
in an associative array.

The covergroups are the real artifact. They are also **inert on EDA
Playground**: Xcelium requires coverage enabled at elaboration
(`-coverage functional`), the Playground command line is fixed and does not pass
it, and the result is not an error but a silent `0.00%`:

```
*N,COVNSM: Sampling of covergroup type "axi_coverage::cg_transaction_type"
is not enabled. As a result, get_inst_coverage() will return 0 coverage.
```

Xcelium says so explicitly; a quieter tool would have shown zero and left the
project believing coverage was genuinely zero. The hand tally cannot be
disabled by a tool switch, and it reports **missing bins by name** rather than
only a percentage — `cg_wstrb 12.50%` says how far there is to go, `missing:
0000 0001 0010 ...` says what to write.

That distinction is what closed three groups on 21 August: the first
measurement named `INT_ENABLE`, `offset_1`, `offset_3` and fourteen strobe
patterns, and all of them turned out to be transactions nobody had written
rather than anything about the design.
