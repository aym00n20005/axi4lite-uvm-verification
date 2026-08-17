# Local Tooling — measured capability

**16 Aug 2026**, cover counts updated 17 Aug. Measured, not assumed. Every
claim here was produced by running the tool on this project's own files.

---

## Simulator capability

| Tool | Version | Functional sim | Concurrent SVA | Cover properties | UVM |
|---|---|---|---|---|---|
| Icarus Verilog | 13.0 | yes | **no** | no | no |
| Verilator | 5.050 | yes | **yes** | yes | no |
| Riviera-PRO (EDA Playground) | — | yes | yes | yes | **yes** |

### Icarus cannot run this checker

Two independent blockers, both hard:

```
sorry: concurrent_assertion_item not supported.
       Try -gno-assertions or -gsupported-assertions to turn this message off.
```

and it cannot parse the interface's clocking blocks at all — `clocking
master_cb @(posedge ACLK);` is a syntax error, along with `default clocking`,
`default disable iff` and `$stable`.

Icarus is therefore useful only as a **fast functional smoke run** against the
RTL and `sanity_tb.sv`, with the checker and interface excluded from the file
list. That is what `run_sim.sh icarus` does.

### Verilator runs the entire checker

Every assertion and cover property in `axi4lite_protocol_checker` compiles and
executes, and Verilator parses `axi4lite_if.sv` in full including the clocking
blocks. Confirmed live by injecting BUG-002 and watching the assertion fire:

```
[335000] %Error: axi4lite_if.sv:125: Assertion failed in
         sanity_tb.dut.u_chk.a_bvalid_not_early:
         BVALID asserted before both AW and W were accepted
```

This is the local assertion flow. It has **no UVM support**, so the UVM
environment still belongs on EDA Playground with Riviera-PRO, exactly as the
README plans.

## Two Verilator gotchas, both worked around in `scripts/run_sim.sh`

### 1. Build directory cannot contain spaces

```
Unsupported: GNU Make cannot build in directories containing spaces,
build elsewhere: '/Users/ayman/AXI-4 Lite Project/sim/obj_dir'
```

This project's path contains spaces. **Source paths with spaces are fine** —
only the generated-Makefile build directory has to move. `run_sim.sh` puts it
under `$TMPDIR`. Renaming the project directory would also fix it and would
match the README's stated repo name, but is not required.

### 2. `--coverage` crashes; `--coverage-user` does not

```
%Error: Internal Error: rtl/axi4lite_reg_slave.sv:125:10:
        ../V3Localize.cpp:203: AstVarRef not under function
```

A Verilator internal error, not a defect in this code. `--coverage` implies
line + toggle + user coverage; `--coverage-user` and `--coverage-line` each
build fine on their own, so the crash is in the toggle path. Cover properties
are what matter here, so `run_sim.sh --coverage` passes `--coverage-user`.

Code coverage (line/branch/toggle) therefore comes from Riviera-PRO, not
locally. That is a November milestone anyway.

## Cover-property status

Measured from the two smoke benches, which are not expected to close anything.
Recorded so the September/October coverage work starts from a real baseline
rather than zero.

The checker binds to both slave modules, so each bench reports the covers of
its own instance. Reproduce with `make coverage`.

| Cover point | `sanity_tb` (reg) | `sanity_mem_tb` (mem) | Note |
|---|---|---|---|
| `c_aw_before_w` | 1 | 1 | qualified form — see below |
| `c_w_before_aw` | 1 | 1 | qualified form |
| `c_aw_w_same_cycle` | 11 | 11 | |
| `c_misaligned_aw` | 1 | 1 | |
| `c_misaligned_ar` | 1 | 1 | |
| `c_partial_strobe` | 2 | 6 | the memory bench sweeps each byte lane individually |
| `c_zero_strobe` | 1 | 1 | SLVERR on the register slave, OKAY no-op on memory |
| `c_resp_okay` | 26 | 24 | |
| `c_resp_slverr` | 5 | 2 | memory has only one error class; the register slave has three |
| `c_resp_decerr` | **0** | **0** | correct — DECERR comes from the interconnect, September |
| `c_b2b_write` | **0** | **0** | both benches leave a gap between transactions |
| `c_b2b_read` | **0** | **0** | as above |
| `c_write_backpressure` | **0** | **0** | `BREADY`/`RREADY` tied high in both benches |
| `c_read_backpressure` | **0** | **0** | as above |

All five zeros are expected and attributable, not unexplained holes.

`c_resp_slverr` at 5 versus 2 is the numeric shadow of a design difference: the
register slave has three error classes in a priority cascade (misaligned,
unimplemented offset, partial strobe), the memory slave has one (misaligned).

## Defect found in the checker's ordering covers

`c_aw_before_w` and `c_w_before_aw` were written unqualified:

```systemverilog
c_w_before_aw : cover property (w_acc ##[1:$] aw_acc);     // v0.2
```

**This is satisfied across transactions.** Any W accept followed eventually by
any AW accept matches — which happens in any multi-transaction run regardless
of the ordering inside each transaction. The cover point reads as covered while
proving nothing about driver independence, which is the entire reason the
verification plan lists it.

Qualified on the checker's own pending-flags:

```systemverilog
c_w_before_aw : cover property ((w_acc && !aw_pend) ##[1:$] (aw_acc && w_pend && !b_done));
```

`w_pend` can only still be set at the AW accept if no B response intervened,
and a B response cannot occur without `aw_pend`. The `!b_done` term excludes
the one remaining escape: a back-to-back accept landing on the cycle the
previous response completes.

**Measured effect:** on an unchanged testbench the counts fell from **10 to 1**
for each — from ten spurious cross-transaction matches to the one genuine
occurrence each that `sanity_tb` actually contains. That difference is the
whole argument.
