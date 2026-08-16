# AXI4-Lite Peripheral Subsystem — UVM-Based Design Verification

A UVM verification environment for an AXI4-Lite peripheral subsystem: an address-decoding interconnect, a register-file slave with mixed access policies (RW / RO / W1C), and a byte-addressable memory slave.

**Status: in progress.** Spec frozen at v0.2 on 12 August 2026, currently v0.3 — see `docs/dut_spec.md` §10 for every revision and its rationale. See milestones below for what is and isn't built. Claims here are limited to what actually runs.

`SystemVerilog` · `UVM` · `SVA` · `UVM RAL` · `Functional Coverage` · `AXI4-Lite`

---

## Why this project

Verification, not design. The RTL is deliberately small so effort goes into methodology: a written verification plan that precedes the code, protocol assertions bound to the DUT, constrained-random stimulus with independent per-channel timing, a scoreboard with a reference model, a RAL register model, and a documented bug database proving the testbench actually catches things.

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
│   └── bug_reports/
├── scripts/
└── README.md
```

## Milestones

| Target | Milestone | Status |
|---|---|---|
| 31 Aug 2026 | Both slaves' RTL, UVM agent, smoke test passing, protocol checker bound and proven by a deliberate break | in progress |
| 30 Sep 2026 | Interconnect, decode, DECERR, scoreboard with reference model | not started |
| 31 Oct 2026 | RAL model, coverage model, backpressure randomisation | not started |
| 30 Nov 2026 | Coverage closure, regression scripting, bug database, formal experiment | not started |
| 31 Dec 2026 | Documentation complete | not started |

## Results

*(Nothing goes here until it is measured. Empty is honest; invented numbers are not.)*

| Metric | Value |
|---|---|
| Tests passing | — |
| Functional coverage | — |
| Code coverage | — |
| Bugs found and root-caused | — |

## Tools

- **Simulation:** EDA Playground with Aldec Riviera-PRO (free, full UVM support, Google login is sufficient)
- **Quick RTL checks:** Icarus Verilog / Verilator — no UVM
- **Formal (planned, Nov):** SymbiYosys + Yosys
- **Version control:** Git

## Documentation

- [Verification plan](docs/verification_plan.md) — features F01–F29, methods, coverage model, test list, open questions
- [DUT specification](docs/dut_spec.md) — the source of truth for all DUT behaviour

## References

- ARM AMBA AXI Protocol Specification (AXI4-Lite chapter)
- IEEE 1800-2017 SystemVerilog LRM · UVM 1.2 / IEEE 1800.2
- OpenHW Group `core-v-verif` — referenced for verification-plan structure and bug-tracking practice

---

## Schedule to DVCon (12 Aug – 1 Sep 2026)

Today is Wednesday 12 August. DVCon India opens Tuesday 1 September. That is **20 days**.

| Date | Day | Task |
|---|---|---|
| Wed 12 Aug | Wed | **Spec freeze.** Read `dut_spec.md` and `verification_plan.md` end to end. Edit anything you disagree with — it's your spec, not mine. Register for DVCon. |
| Thu 13 Aug | Thu | Read the AXI4-Lite chapter of the AMBA spec. Draw AW/W/B/AR/R and the handshake rules from memory until it's automatic. |
| Fri 14 Aug | Fri | Register slave: architecture on paper first (accept-flags, response FSM, register bank), then start RTL. |
| Sat 15 Aug | Sat | Register slave RTL complete and compiling. |
| Sun 16 Aug | Sun | Sanity TB: one write, one read to `SCRATCH`, `$display` the readback. |
| Mon 17 Aug | Mon | Memory slave RTL with real `WSTRB` masking. |
| Tue 18 Aug | Tue | Memory sanity TB. Partial write proves only strobed bytes changed. |
| Wed 19 Aug | Wed | Bind `axi4lite_protocol_checker` to both slaves. Fix whatever fires. |
| Thu 20 Aug | Thu | **Break it deliberately.** Inject BUG-002 (BVALID before W accepted). Watch `a_bvalid_not_early` fire. Revert. |
| Fri 21 Aug | Fri | UVM fundamentals: phases, `uvm_component` hierarchy, `config_db`, factory. Hello-world on EDA Playground. |
| Sat 22 Aug | Sat | UVM fundamentals continued. Understand the sequence/sequencer/driver handshake before writing any. |
| Sun 23 Aug | Sun | `axi_transaction` + `axi_sequencer`. |
| Mon 24 Aug | Mon | `axi_driver` — write path, with `fork`-based per-channel threads from the start. |
| Tue 25 Aug | Tue | `axi_driver` — read path. Write-then-readback working. |
| Wed 26 Aug | Wed | `axi_monitor`. Verify it reconstructs transactions independently of the driver. |
| Thu 27 Aug | Thu | Minimal scoreboard: associative-array reference model, compare on reads. |
| Fri 28 Aug | Fri | Randomise VALID delays and READY backpressure. Confirm `c_w_before_aw` is covered. |
| Sat 29 Aug | Sat | Clean the repo, finish this README, write the one-page PDF brief. |
| Sun 30 Aug | Sun | DVCon rehearsal: explain the project in 90 seconds, then 20. Record yourself. Booth research. |
| Mon 31 Aug | Mon | **Freeze the conference build.** No new code. Print the vplan and one-pagers. Pack. |
| Tue 1 Sep | Tue | DVCon India, Day 1. |

**Thursday 20 August is the important one.** An assertion you have never seen fail is an assertion you don't know works — and "I broke my own DUT to prove my checker caught it" is a sentence worth saying out loud at DVCon.
