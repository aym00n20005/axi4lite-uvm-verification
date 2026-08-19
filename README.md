# AXI4-Lite Peripheral Subsystem — UVM-Based Design Verification

A UVM verification environment for an AXI4-Lite peripheral subsystem: an address-decoding interconnect, a register-file slave with mixed access policies (RW / RO / W1C), and a byte-addressable memory slave.

**Status: in progress.** Spec frozen at v0.2 on 12 August 2026, currently v0.3 — see `docs/dut_spec.md` §10 for every revision and its rationale. See milestones below for what is and isn't built. Claims here are limited to what actually runs.

`SystemVerilog` · `UVM` · `SVA` · `UVM RAL` · `Functional Coverage` · `AXI4-Lite`

---

## Why this project

Verification, not design. The RTL is deliberately small so effort goes into methodology: a written verification plan that precedes the code, protocol assertions bound to the DUT, constrained-random stimulus with independent per-channel timing, a scoreboard with a reference model, a RAL register model, and a documented bug database proving the testbench actually catches things.

## Two tracks, one repository

This repo contains the verification environment **and the flow that runs it**, because the second exists to serve the first:

| Track | What it is | Where |
|---|---|---|
| **Verification** | UVM environment, SVA protocol checker, scoreboard, RAL, coverage model | `rtl/`, `tb/`, `docs/verification_plan.md` |
| **Flow automation** | Regression runner, log parser with failure signatures, triage, register generator, coverage and vplan reporting | `scripts/`, [docs/automation_plan.md](docs/automation_plan.md) |

The automation is not a side project. Once there are more than a handful of tests and multiple seeds, running by hand stops being viable — coverage closure is only reachable through the regression flow, and the register bank, the RAL model and the register documentation are generated from one YAML source so they cannot drift apart. The automation track starts **after 31 August**; before then the only tooling here is `scripts/run_sim.sh` and a minimal `make test`.

## Architecture

```
                    ┌─────────────────────────────┐
   AXI4-Lite        │                             │
   Master ─────────▶│   AXI4-Lite Interconnect    │
   (UVM agent)      │   (address decode + mux)    │
                    └──────┬───────────────┬──────┘
                           │               │
                  0x0000_0000      0x0000_1000
                           │               │
                    ┌──────▼──────┐  ┌─────▼──────┐
                    │  Register   │  │   Memory   │
                    │  File Slave │  │   Slave    │
                    │  RW/RO/W1C  │  │   1 KB     │
                    └─────────────┘  └────────────┘

              0x0000_1400 and above → DECERR
```

## Verification environment

```
                        uvm_test
                           │
                       axi_env
        ┌──────────────┬────┴─────┬──────────────┐
        │              │          │              │
  axi_master_agent  scoreboard  coverage     axi_reg_block
   ┌────┴────┐      (ref model)  collector      (RAL)
   │sequencer│                                     │
   │ driver  │◀────────── reg_adapter ─────────────┘
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

## Repository layout

```
axi4lite-uvm-verification/
├── rtl/
│   ├── axi4lite_reg_slave.sv
│   ├── axi4lite_mem_slave.sv
│   └── axi4lite_interconnect.sv
├── tb/
│   ├── interface/          # axi4lite_if.sv + bound protocol checker
│   ├── agent/              # transaction, sequencer, driver, monitor, agent
│   ├── sequences/
│   ├── env/                # env, scoreboard, coverage
│   ├── ral/                # uvm_reg_block + adapter
│   └── tests/
├── docs/
│   ├── verification_plan.md
│   ├── dut_spec.md
│   ├── automation_plan.md
│   └── bug_reports/
├── scripts/                # run_sim.sh today; Makefile + Python flow from September
└── README.md
```

## Milestones

| Target | Verification | Flow automation | Status |
|---|---|---|---|
| 31 Aug 2026 | Both slaves' RTL, UVM agent, smoke test passing, protocol checker bound and proven by a deliberate break | `make test` only — nothing else before DVCon | in progress |
| 30 Sep 2026 | Interconnect, decode, DECERR, scoreboard with reference model | Regression runner (parallel seeds, `results.json`), log parser with failure signatures | not started |
| 31 Oct 2026 | RAL model, coverage model, backpressure randomisation | Failure-signature triage; register generator emitting RTL bank + RAL + docs from `regmap.yaml` | not started |
| 30 Nov 2026 | Coverage closure, bug database, formal experiment | Coverage trend reporting, vplan traceability matrix, measured LLM triage assist | not started |
| 31 Dec 2026 | Documentation complete | Toolkit documented and cleaned up | not started |

The October RAL model is *generated*, not hand-written — that is the point at which the two tracks stop being parallel and start depending on each other.

## Results

*(Nothing goes here until it is measured. Empty is honest; invented numbers are not.)*

| Metric | Value |
|---|---|
| Tests passing | 58 **smoke** checks — 31 register slave, 27 memory slave — under both Icarus 13.0 and Verilator 5.050 |
| Functional coverage | not started; cover-property baseline in [tooling notes](docs/tooling_notes.md) |
| Code coverage | not started — needs a commercial simulator |
| Bugs found and root-caused | 1 genuine ([BUG-007](docs/bug_reports/BUG-007.md), checker cover defect); 4 injected and detected ([BUG-002](docs/bug_reports/BUG-002.md), BUG-003, v0.2 decode, write-data bypass) |

**Read "tests passing" narrowly.** Those are non-UVM smoke checks from
`tb/sanity_tb.sv` and `tb/sanity_mem_tb.sv` — no scoreboard, no randomisation,
no coverage. They prove the RTL breathes; they are not verification, and the
number will be replaced by the UVM test list once it exists.

## Tools

- **UVM simulation:** EDA Playground with **Cadence Xcelium** (CDNS-UVM-1.2). Aldec Riviera-PRO compiles UVM there but cannot simulate it — the free entitlement excludes class-based simulation, signed in or not. Measured 19 Aug; see [tooling notes](docs/tooling_notes.md).
- **Quick RTL checks:** Icarus Verilog / Verilator — no UVM
- **Formal (planned, Nov):** SymbiYosys + Yosys
- **Flow (from Sep):** Make + Python (regression, parsing, code generation), TCL for simulator control
- **Version control:** Git

## Documentation

- [Verification plan](docs/verification_plan.md) — features F01–F29, methods, coverage model, test list, open questions
- [DUT specification](docs/dut_spec.md) — the source of truth for all DUT behaviour
- [Automation plan](docs/automation_plan.md) — the regression, triage and register-generation flow that runs the above
- [Tooling notes](docs/tooling_notes.md) — measured simulator capability, not assumed
- [Bug reports](docs/bug_reports/) — every bug, injected or genuine, with evidence and root cause

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
