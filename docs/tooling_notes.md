# Local Tooling — measured capability

Measured, not assumed. Every claim here was produced by running the tool on this
project's own files, and the entries that cost the most time are the ones about
what a tool *accepts* rather than what it rejects.

---

## Tool capability

| Tool | Version | Functional sim | Concurrent SVA | Cover properties | UVM | Elaboration | Formal |
|---|---|---|---|---|---|---|---|
| Icarus Verilog | 13.0 | yes | **no** | no | no | — | no |
| Verilator | 5.050 | yes | **yes** | yes | no | yes | no |
| slang | 11.0 | **no** | parses | parses | **elaborates** | **yes** | no |
| Yosys + z3 | 0.68 / 5.1.0 | no | **no** | no | no | limited | **yes** |
| Riviera-PRO (EDA Playground) | 2025.04 | yes | yes | yes | compiles only | yes | no |
| Xcelium (EDA Playground) | 25.03 | yes | yes | yes | **yes** | yes | no |

Six tools, and no two of them can do the same job. That is the shape of the
whole flow: `make elab` is slang, `make test` and `make regression` are
Verilator, `make formal` is Yosys, and the UVM environment is Xcelium in a
browser.

---

## slang — the elaboration gate

slang cannot simulate. It **elaborates**, which turns out to be most of the
value: UVM runs only on EDA Playground, by hand, so every typo
used to cost a browser round trip measured in minutes. slang elaborates the
generated bundle — byte for byte, the same file that gets pasted — in about a
fifth of a second.

```
  sys          Build succeeded: 0 errors, 2 warnings  top=tb_top_sys
  ral          Build succeeded: 0 errors, 2 warnings  top=tb_top_sys
  rand         Build succeeded: 0 errors, 2 warnings  top=tb_top_sys
  ...
elab: all bundles elaborate -- 0 errors
```

Two flags are load-bearing and neither is cosmetic:

- **`--timescale=1ns/1ps`.** Only `rtl/axi4lite_reg_slave.sv` declares a
  `` `timescale ``, and slang treats a partially-timescaled design as an error
  because its semantics are then tool-dependent. Xcelium applies its own default
  and says nothing.
- **`-I third_party/uvm-1.2/src`.** UVM **1.2**, matching the CDNS-UVM-1.2 that
  Xcelium actually supplies. Elaborating against 2020-2.0 would report errors
  Xcelium will not and miss ones it will.

### What it found on its first run

Two errors, one defect: `soft (a) -> b dist {...}` in `axi_transaction.sv`
selects the wrong production of IEEE 1800-2017's constraint grammar. Xcelium
accepts it; every number this project had published came through it. See
[BUG-010](bug_reports/BUG-010.md).

**The general lesson is worth more than the bug.** Until an elaboration gate existed, everything
here had been validated by exactly one simulator, which means it had been
validated against that simulator's *extensions* as much as against the language.
A second conformant front end is cheap insurance, and 0.2 seconds is not a
budget item.

It has since caught three more portability traps that no simulation would have:
a class property referenced above its own declaration, a `wire` referenced above
its declaration in the interconnect, and the same in a sequence.

---

## Yosys — the formal frontend, and its limits

Yosys 0.68 with `yosys-smtbmc` and Z3 5.1.0, all from Homebrew. SymbiYosys is *not* installed: it drives `yosys-smtbmc`, which ships
with Yosys, so calling that directly removes a source-build dependency.

**Yosys's open-source frontend supports no concurrent SVA at all.** Measured, one
form at a time:

| Written | Yosys |
|---|---|
| `default clocking @(posedge ACLK); endclocking` | `ERROR: unexpected TOK_DEFAULT` |
| `assert property (@(posedge ACLK) …);` | `ERROR: unexpected '@'` |
| `assert (a \|=> b);` | `ERROR: unexpected TOK_BIT_OR_ASSIGN` |
| `property pr; … endproperty` | `ERROR: unexpected TOK_PROPERTY` |
| `import pkg::*;` inside a module | `ERROR: unexpected TOK_IMPORT` |
| a wrapper referencing `dut.signal` | `ERROR: Identifier is implicitly declared` |
| `bind` | no support |

What it accepts in `-formal` mode is the **immediate** assertion inside a clocked
`always` block, plus `$past`. The consequences and the full write-up are in
[formal_notes.md](formal_notes.md); the short version is that the 23 assertions
in `axi4lite_if.sv` cannot be reused, so the formal properties are a separate,
deliberately small set.

Two further requirements, both traceable to spec §1's reset contract:

- **`async2sync; dffunmap` before `write_smt2`.** An asynchronous reset infers
  `$adff` cells, which `write_smt2` cannot model.
- **Relative paths.** Yosys splits a `-p` script on whitespace, and this
  project's directory name contains spaces:
  `ERROR: File `Lite' not found or is a directory`. The same trap as Verilator's
  build directory, in a different tool — see below.

---

## Icarus cannot run this checker

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

## Verilator runs the entire checker

Every assertion and cover property in `axi4lite_protocol_checker` compiles and
executes, and Verilator parses `axi4lite_if.sv` in full including the clocking
blocks. Confirmed live by injecting BUG-002 and watching the assertion fire:

```
[335000] %Error: axi4lite_if.sv:125: Assertion failed in
         sanity_tb.dut.u_chk.a_bvalid_not_early:
         BVALID asserted before both AW and W were accepted
```

This is the local assertion flow. It has **no UVM support**, so the UVM
environment runs on EDA Playground — with **Xcelium**, not Riviera; see the
19 August section at the end of this file for why.

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

Code coverage (line/branch/toggle) therefore comes from a commercial simulator,
and **it is the one thing in this project that was not done**.

Stated plainly rather than left as a milestone that quietly lapsed: Verilator's
`--coverage-line` builds, but line coverage of the RTL is a weak metric here --
the design is 900 lines and every line is exercised by the directed benches. The
metric worth having is toggle and branch coverage from Xcelium, and Xcelium is
only reachable through EDA Playground, whose command line is fixed and cannot
pass `-coverage all`. The same fixed command line that makes the functional
covergroups report a silent `0.00%`.

So: not available, for the same measured reason, and not claimed.

## Cover-property status

**Every cover property is now non-zero**, and the interesting part is *where*.

Measured by `make coverage`, which runs all four local benches with
`--coverage-user` and reports per checker **instance**. Full tables, regenerated
on every run, are in [coverage_report.md](coverage_report.md).

The system benches carry three checker instances — one on the interconnect's
master-facing port and one inside each slave — and the difference between the
columns is the result rather than noise:

| Cover point | master port | slave ports | what the split says |
|---|---|---|---|
| `c_resp_decerr` | **195** | **0** | Spec §4's claim, measured: the interconnect produces `DECERR` and no slave can |
| `c_w_before_aw` | **127** | **0** | The interconnect absorbs the AW/W ordering — it forwards both halves together, so W-before-AW is a property of the master port only |
| `c_b2b_write` | **650** | 0 | Likewise: the interconnect inserts response states, so it never issues back-to-back to a slave |
| `c_write_backpressure` | **2793** | 0 | It raises its own BREADY the cycle a slave responds, so it never stalls one |

None of the right-hand zeros is a stimulus gap. Each is a structural consequence
of what the interconnect does, and each is written down here and in
[interconnect_architecture.md](interconnect_architecture.md) so it is never
"closed" by adding stimulus that cannot reach it.

### The five that used to be permanently zero

`c_b2b_write`, `c_b2b_read`, `c_write_backpressure`, `c_read_backpressure` and
`c_resp_decerr` read 0 in every run this project made before the seeded random bench existed. Four of
them needed a driver that keeps the *next* transaction's VALID asserted while the
current one is still completing, which `tb/sanity_rand_tb.sv` does and no
directed bench can. The fifth needed an interconnect to exist.

Both were closed **locally, under Verilator**, without a commercial simulator.

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

---

## UVM simulator — measured 19 August 2026

The README originally named Aldec Riviera-PRO as the UVM simulator, on the
assumption that a Google login was sufficient. That is wrong, and it was worth
finding out on the 19th rather than the 27th.

| Simulator (EDA Playground) | Compiles UVM | Simulates UVM |
|---|---|---|
| Aldec Riviera-PRO 2025.04 | **yes** — 0 errors, 0 warnings | **no** |
| Cadence Xcelium 25.03 (CDNS-UVM-1.2) | yes | **yes** |

Riviera compiles cleanly and then refuses at elaboration:

```
ELBREAD: Error: You do not have a valid license to simulate module
"uvm_1_2.\uvm_pkg uvm_bottomup_phase \" using SystemVerilog advanced
verification features.
```

`vlog` is licensed; `vsim` on class-based code is not. Being signed in does not
change it — this was tested logged in. The failure is an entitlement boundary,
not a configuration mistake, so there is nothing to fix on our side.

**Xcelium is therefore the UVM simulator for this project.** Selected from the
EDA Playground dropdown; no other change to the source.

Two consequences worth carrying:

- **Reproducibility.** Xcelium reports `SVSEED default: 1`, and two runs of the
  same test produced byte-identical randomisation. Good for debugging, and the
  reason the verification plan's bug-report template has a *seed* field — a
  seed only means something once it is recorded. Randomised regression will
  need seeds passed explicitly rather than relying on the default.
- **UVM version.** Xcelium supplies its own CDNS-UVM-1.2 via `-uvmhome`, built
  with `UVM_NO_DEPRECATED` undefined. Deprecated UVM 1.1 constructs will
  therefore compile here and may not elsewhere. Worth avoiding them
  deliberately rather than by luck.

Local `make test` is unaffected and stays the RTL regression: Icarus and
Verilator have no UVM support and never will for this project's purposes.

**The seed is no longer fixed.** Playground's command line
cannot pass `+SVSEED`, so it arrives as a define written into the generated
bundle by `make playground PLAY=x SEED=n`, and the sequence seeds its own
process with it. `axi_multiseed_test` runs eight seeds inside one simulation,
because Playground cannot launch eight runs either.

---

## What each tool is used for, in the end

| Command | Tool | What it decides |
|---|---|---|
| `make elab` | slang | Does the UVM source mean what it says, in any conformant tool |
| `make lint` | Verilator | Is the RTL clean at `-Wall` |
| `make test` | Verilator | Do the three directed benches pass, with all assertions live |
| `make regression` | Verilator | Ten random seeds, unattended, in 12 seconds |
| `make formal` | Yosys + z3 | The same-cycle rules no simulation here can decide |
| `make playground` → Xcelium | Xcelium | The UVM environment: scoreboard, coverage model, RAL |

The last row is the only one with a person in it, and that is a property of the
tools rather than of the flow: no free simulator runs UVM.
