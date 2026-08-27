# AXI4-Lite Peripheral Subsystem — UVM-Based Design Verification

A UVM verification environment for two AXI4-Lite slaves — a register file with mixed access policies (RW / RO / W1C) and a byte-addressable memory. The design is deliberately small so the effort goes into the methodology.

**Status: in progress**, and the plan runs to December. The interconnect and the
RAL model are **not built yet** — they are September and October milestones, and
their absence is why `DECERR` is unreachable and two coverage bins stay open.
Every figure below came from a run; nothing is projected.

`SystemVerilog` · `UVM` · `SVA` · `Functional Coverage` · `Constrained Random` · `AXI4-Lite`

---

## Why this project

Verification, not design.

**Built and running:** a verification plan written before the code, 23 SVA
assertions bound to the DUT, constrained-random stimulus with independent
per-channel timing, a passive monitor that rebuilds transactions from pins only,
a scoreboard whose reference model is derived from the specification rather than
the RTL, a functional coverage model, and a bug database proving the testbench
catches things.

**Planned:** address-decoding interconnect (September), RAL register model
generated from a YAML description (October), formal experiment (November).

## What the testbench found

Nine bugs. Six planted deliberately to prove the environment works; **three
real, and all three were in the testbench rather than the design.**

- **A cover point that could not fail to be covered.** The property meant to
  prove the driver's threads run independently was satisfied by *any*
  multi-transaction run, so it could never warn about anything. Qualifying it
  dropped the hit count from **10 to 1** on identical stimulus.
  ([BUG-007](docs/bug_reports/BUG-007.md))
- **An assertion that failed on correct hardware.** Its timing window assumed a
  delay the *master* controls and the spec does not bound. Found by random
  traffic on its first run, and unreachable by every directed test that
  existed — all of them used delays inside the window.
  ([BUG-008](docs/bug_reports/BUG-008.md))
- **A driver race that passed for eleven days on timing luck**, through 44
  directed checks and 166 random transactions, until a second DUT shifted the
  schedule. ([BUG-009](docs/bug_reports/BUG-009.md))
- **Two contradictions in the frozen specification**, found while deriving the
  architecture on paper — before any RTL existed. Both fixed in the document
  first. ([dut_spec.md §10](docs/dut_spec.md))

Two results from the planted bugs are worth more than the detections:

- Injecting a real defect and removing **one stimulus case** left a correct,
  bound assertion silent while **31 of 31 checks passed** on a broken design. A
  checker constrains nothing if the stimulus never reaches the corner.
  ([BUG-002](docs/bug_reports/BUG-002.md))
- A protocol violation injected into the driver passed **every functional check
  with `UVM_ERROR: 0`**. Functional correctness and protocol compliance are
  independent properties. ([BUG-001](docs/bug_reports/BUG-001.md))

## Results

*(Nothing goes here until it is measured. Empty is honest; invented numbers are not.)*

| Metric | Value |
|---|---|
| UVM tests | `axi_smoke_test` **44/44 checks** · `axi_random_test` **166 constrained-random transactions, 0 scoreboard mismatches** (Xcelium 25.03) |
| Non-UVM smoke | **58 checks** — 31 register, 27 memory — under both Icarus 13.0 and Verilator 5.050 |
| Functional coverage | 8 groups measured per test. `axi_smoke_test` closes 6/8; `axi_random_test` closes 6/8 on a different set. Every open bin justified in [coverage status](docs/coverage_status.md) |
| Code coverage | not started — needs a commercial simulator invoked with coverage enabled |
| Bugs found and root-caused | **3 genuine, all in the testbench** — [BUG-007](docs/bug_reports/BUG-007.md) a cover point that could not fail to be covered; [BUG-008](docs/bug_reports/BUG-008.md) an assertion that failed on correct hardware; [BUG-009](docs/bug_reports/BUG-009.md) a driver race that passed for eleven days on timing luck. **4 of the 6 planned injections detected**, each by the mechanism §9 assigns it — [BUG-002](docs/bug_reports/BUG-002.md) by SVA, [BUG-003](docs/bug_reports/BUG-003.md) by the scoreboard, [BUG-006](docs/bug_reports/BUG-006.md) by a directed test, [BUG-001](docs/bug_reports/BUG-001.md) by SVA against a deliberately broken **driver** — which passed every functional check and reported `UVM_ERROR: 0`. BUG-004 needs the RAL, BUG-005 the interconnect |

**Read these narrowly.** Two UVM tests against one slave — the memory slave is
not yet in the UVM environment, and there is no interconnect, so `DECERR` and
routed memory traffic are unreachable. Coverage is per-test and not merged;
merging across a regression is a September job. Neither number is a closure
figure.

Every response is checked against a reference model derived from the spec, fed
by a monitor that reconstructs from pins and has no access to the driver. Read
data the model **cannot** predict — `COUNTER`, `STATUS.busy`, `INT_STATUS[3]` —
is reported as skipped rather than silently passed.

**Both genuine bugs were false confidence, not missed detection.** One metric
that could not fail to look good, one checker that cried wolf on a correct DUT.
The checker gets the same scrutiny as the design.

## Architecture

The target subsystem. **Solid boxes exist and are verified; the dashed one does
not exist yet.**

```
                    ╔═════════════════════════════╗
   AXI4-Lite        ║   AXI4-Lite Interconnect    ║  <-- NOT BUILT
   Master ─────────▶║   (address decode + mux)    ║      September milestone
   (UVM agent)      ╚══════╤═══════════════╤══════╝
                           ┊               ┊
                  0x0000_0000      0x0000_1000
                           ┊               ┊
                    ┌──────▼──────┐  ┌─────▼──────┐
                    │  Register   │  │   Memory   │   both built, both
                    │  File Slave │  │   Slave    │   verified against a
                    │  RW/RO/W1C  │  │   1 KB     │   spec-derived model
                    └─────────────┘  └────────────┘

              0x0000_1400 and above → DECERR
              (unreachable until the interconnect exists — neither slave
               contains a code path that can emit it, by design)
```

**Today** each UVM test drives one slave directly: `tb_top` for the register
file, `tb_top_mem` for the memory. Nothing routes, so each slave decodes the
whole address space onto its own offset — correct behaviour, and the reason
`cg_address_region` records addresses *issued* rather than traffic *routed*.
That distinction is written up rather than glossed over, in
[coverage status](docs/coverage_status.md).

## Verification environment

**Solid exists and runs; dashed is planned.**

```
                        uvm_test
                           │
                       axi_env
        ┌──────────────┬────┴─────┬─ ─ ─ ─ ─ ─ ─ ┐
        │              │          │
  axi_master_agent  scoreboard  coverage     axi_reg_block
   ┌────┴────┐      (ref model)  collector      (RAL)      <-- NOT BUILT
   │sequencer│                                     ┊           October
   │ driver  │◀ ─ ─ ─ ─ ─  reg_adapter  ─ ─ ─ ─ ─ ─┘
   │ monitor │
   └────┬────┘
        │
    axi4lite_if ──── axi4lite_protocol_checker (SVA, bound)
        │
       DUT
```

**Driver design note:** one thread per AXI channel (`fork ... join_none`), not a single sequential FSM. AW and W are independent channels in AXI4-Lite; driving them in lockstep would never exercise W-before-AW ordering and would hide slave-side ordering bugs. The cover property `c_w_before_aw` exists to prove the threads are genuinely independent.

## Key design decisions

Each of these is a deliberate scope choice, recorded so it is never mistaken for an oversight:

| Decision | Rationale |
|---|---|
| AXI4-Lite, not full AXI | Establish methodology before protocol complexity. Bursts and IDs are a planned extension. |
| One outstanding read + one outstanding write | Keeps reorder buffers and response queues out of scope. |
| `COUNTER` is 16-bit, not 32-bit | A 32-bit counter overflows after ~43 s of simulated time; the overflow event would be dead code and its coverage bin would never close. |
| `STATUS.busy` covers the write path only | If it covered reads, reading `STATUS` would itself be an in-flight read and the bit could never read 0. |
| `BVALID`/`RVALID` assert no earlier than one cycle after their accepts | Registered slave. The AMBA spec permits same-cycle for a combinational slave; excluded here so the checker can use registered pending-flags. |
| Unmapped gap at `0x1400`–`0x1FFF` | Makes the address decode non-trivial and the DECERR path reachable from a plausible-looking address. |

## Two tracks, one repository

This repo contains the verification environment **and the flow that runs it**, because the second exists to serve the first:

| Track | What it is | Where |
|---|---|---|
| **Verification** | UVM environment, SVA protocol checker, scoreboard, coverage model; RAL from October | `rtl/`, `tb/`, `docs/verification_plan.md` |
| **Flow automation** | Regression runner, log parser with failure signatures, triage, register generator, coverage and vplan reporting | `scripts/`, [docs/automation_plan.md](docs/automation_plan.md) |

The automation is not a side project. Once there are more than a handful of tests and multiple seeds, running by hand stops being viable — coverage closure is only reachable through the regression flow, and the register bank, the RAL model and the register documentation are generated from one YAML source so they cannot drift apart. The automation track starts **after 31 August**; before then the only tooling here is `scripts/run_sim.sh` and a minimal `make test`.

## Repository layout

```
axi4lite-uvm-verification/
├── rtl/
│   ├── axi4lite_reg_slave.sv      8 registers, RW/RO/W1C, error precedence
│   └── axi4lite_mem_slave.sv      256 words, WSTRB byte masking
├── tb/
│   ├── interface/                 axi4lite_if.sv + protocol checker, one bind per slave
│   ├── agent/                     transaction, sequencer, driver, monitor, agent
│   ├── sequences/                 smoke, random and memory sequences
│   ├── env/                       env, scoreboard, coverage collector
│   ├── tests/                     3 UVM tests + two testbench tops
│   ├── uvm/                       standalone benches: UVM hello, constraint smoke, BUG-006 minimal
│   ├── sanity_tb.sv               non-UVM smoke bench, register slave
│   └── sanity_mem_tb.sv           non-UVM smoke bench, memory slave
├── docs/                          spec, plan, architecture notes, 7 bug reports, walkthrough
├── scripts/run_sim.sh             local Verilator / Icarus flow
├── Makefile                       make test | coverage | lint | playground
└── README.md
```

**Not yet built**, and named here so their absence is not mistaken for an
oversight: `rtl/axi4lite_interconnect.sv` (September, and until it exists
`DECERR` is unreachable), and `tb/ral/` (October, generated from a YAML register
description rather than hand-written).

## Milestones

Status as of 28 August 2026. Several later items were pulled forward; the ones
that were not are blocked on components that do not exist, not on effort.

| Target | Verification | Flow automation | Status |
|---|---|---|---|
| 31 Aug 2026 | Both slaves' RTL, UVM agent, smoke test passing, protocol checker bound and proven by a deliberate break | `make test` only — nothing else before DVCon | **complete** (20 Aug) |
| 30 Sep 2026 | Interconnect, decode, DECERR, scoreboard with reference model | Regression runner (parallel seeds, `results.json`), log parser with failure signatures | **scoreboard done early**; interconnect not started |
| 31 Oct 2026 | RAL model, coverage model, backpressure randomisation | Failure-signature triage; register generator emitting RTL bank + RAL + docs from `regmap.yaml` | **coverage model done early**; RAL not started |
| 30 Nov 2026 | Coverage closure, bug database, formal experiment | Coverage trend reporting, vplan traceability matrix, measured LLM triage assist | **bug database done early** (7 reports); closure partial; formal not started |
| 31 Dec 2026 | Documentation complete | Toolkit documented and cleaned up | **substantially done early** |

Pulled forward because they turned out to be prerequisites rather than
successors: the scoreboard was needed before random traffic meant anything, the
coverage model before "how much have I tested" could be answered with a number,
and the bug database from the first injection onward, because a bug written up
a week later is a bug half-remembered.

Still blocked, and each blocks something specific: the **interconnect** blocks
`DECERR`, two coverage bins and BUG-005; the **RAL** blocks BUG-004. Neither is
a time problem.

The October RAL model is *generated*, not hand-written — that is the point at which the two tracks stop being parallel and start depending on each other.

## Tools

- **UVM simulation:** EDA Playground with **Cadence Xcelium** (CDNS-UVM-1.2). Aldec Riviera-PRO compiles UVM there but cannot simulate it — the free entitlement excludes class-based simulation, signed in or not. Measured 19 Aug; see [tooling notes](docs/tooling_notes.md).
- **Quick RTL checks:** Icarus Verilog / Verilator — no UVM
- **Formal (planned, Nov):** SymbiYosys + Yosys
- **Flow (from Sep):** Make + Python (regression, parsing, code generation), TCL for simulator control
- **Version control:** Git

## Documentation

**Start here:** [project walkthrough](docs/project_walkthrough.md) — the whole
project explained from zero, including every bug and what it taught.

| | |
|---|---|
| [DUT specification](docs/dut_spec.md) | source of truth; §10 is the revision history with a test per revision |
| [Verification plan](docs/verification_plan.md) | features F01–F29, coverage model, test list |
| [Bug reports](docs/bug_reports/) | 7 written up, injected and genuine |
| [Coverage status](docs/coverage_status.md) | measured, with a written justification per open bin |
| [Tooling notes](docs/tooling_notes.md) | measured simulator capability, not assumed |
| [Register slave architecture](docs/reg_slave_architecture.md) · [memory slave](docs/mem_slave_architecture.md) | design decided on paper before RTL |
| [UVM agent design](docs/uvm_agent_design.md) · [UVM fundamentals](docs/uvm_fundamentals.md) | testbench decisions and the concepts behind them |
| [Automation plan](docs/automation_plan.md) | the regression and codegen flow, September onward |
| [One-page brief](docs/one_pager.pdf) | printable A4 summary |

## References

- ARM AMBA AXI Protocol Specification (AXI4-Lite chapter)
- IEEE 1800-2017 SystemVerilog LRM · UVM 1.2 / IEEE 1800.2
- OpenHW Group `core-v-verif` — referenced for verification-plan structure and bug-tracking practice

---

## Schedule to DVCon — updated Monday 17 August 2026

DVCon India opens Tuesday 1 September. That is **15 days left**, and the schedule is **two days ahead**: the checker bind and the deliberate-break experiment, planned for 19 and 20 August, both landed on 16 August.

### Done (12–16 Aug)

| Date | Delivered |
|---|---|
| 12–13 Aug | Spec read end to end and revised to **v0.3** (two contradictions, two gaps — `dut_spec.md` §10). AMBA AXI4-Lite chapter. `axi4lite_if.sv` + protocol checker. |
| 14–15 Aug | Register slave: architecture notes first, then RTL complete and compiling. |
| 16 Aug | Sanity TB (write/read `SCRATCH`, readback). Checker **bound** to the register slave. Local sim flow `run_sim.sh` with measured tooling notes. **BUG-002 injected and `a_bvalid_not_early` seen firing** — the 20 Aug item, done four days early. Found and fixed a real defect in the checker's own ordering covers (unqualified, matching across transactions: 10 spurious hits → 1 genuine). |

The checker defect is the strongest thing in the repo right now and it isn't on the original schedule — it is worth rehearsing as its own answer.

### Remaining (17–31 Aug)

| Date | Day | Task |
|---|---|---|
| 17 Aug | Mon | Memory slave RTL with real `WSTRB` masking. Extend `axi4lite_checker_bind.sv` to it while writing it — the bind pattern already exists. |
| 18 Aug | Tue | Memory sanity TB. Partial write proves only strobed bytes changed. Re-run `run_sim.sh --coverage`; record the new cover counts in `tooling_notes.md`. |
| 19 Aug | Wed | *(recovered day)* Write up **BUG-002** properly in `docs/bug_reports/` — detection method, waveform evidence, root cause. The experiment is done; the evidence is not captured, and `docs/bug_reports/` is empty. Re-run the injection against the memory slave. |
| 20 Aug | Thu | UVM fundamentals: phases, `uvm_component` hierarchy, `config_db`, factory. Hello-world on EDA Playground. *(pulled forward one day)* |
| 21 Aug | Fri | UVM fundamentals continued. Understand the sequence/sequencer/driver handshake before writing any. |
| 22 Aug | Sat | `axi_transaction` + `axi_sequencer`. |
| 23 Aug | Sun | `axi_driver` — write path, with `fork`-based per-channel threads from the start. |
| 24 Aug | Mon | `axi_driver` — read path. Write-then-readback working. |
| 25 Aug | Tue | `axi_monitor`. Verify it reconstructs transactions independently of the driver. |
| 26 Aug | Wed | Minimal scoreboard: associative-array reference model, compare on reads. |
| 27 Aug | Thu | Randomise VALID delays and READY backpressure. Target the four attributable zeros in `tooling_notes.md`: `c_w_before_aw` on the qualified cover, `c_b2b_write`/`c_b2b_read`, both backpressure covers. |
| 28 Aug | Fri | *(recovered day — buffer)* Absorb whatever slipped. If nothing slipped: the 20-line `make test` Makefile, which is the only automation allowed before 31 Aug. |
| 29 Aug | Sat | Clean the repo, finish this README, write the one-page PDF brief. |
| 30 Aug | Sun | DVCon rehearsal: explain the project in 90 seconds, then 20. Record yourself. Booth research. |
| 31 Aug | Mon | **Freeze the conference build.** No new code. Print the vplan and one-pagers. Pack. |
| 1 Sep | Tue | DVCon India, Day 1. |

**The two recovered days are spent, not banked** — one on documenting the bug that was already found, one as buffer before the freeze. UVM is fifteen days of work compressed into eight; the buffer is what stops the 29 Aug clean-up from being sacrificed to it.

**Both hard deadlines are unchanged:** UVM starts 20 August at the latest, and the build freezes 31 August regardless of what is unfinished.
