# AXI4-Lite Peripheral Subsystem — UVM-Based Design Verification

A UVM verification environment for an AXI4-Lite subsystem: an address-decoding
interconnect, a register file with mixed access policies (RW / RO / W1C / WC),
and a byte-addressable memory. The design is deliberately small so the effort
goes into the methodology.

**Status: complete.** Every feature in the verification plan has a test, every
test has a result, and every uncovered bin has a written justification. Every
figure below came from a run.

`SystemVerilog` · `UVM` · `SVA` · `Functional Coverage` · `Constrained Random` ·
`UVM RAL` · `Formal (BMC)` · `AXI4-Lite`

---

## Why this project

Verification, not design.

A verification plan written before the code. 23 SVA assertions bound to three
ports. Constrained-random stimulus with independent per-channel timing. A passive
monitor that rebuilds transactions from pins only. A scoreboard whose reference
model is derived from the specification rather than the RTL. Eleven functional
covergroups fed from observation. A RAL model generated from the same YAML that
generates the RTL's register map. A bounded model check for the rules simulation
cannot decide. And a flow that runs all of it.

## The result worth leading with

A defect was injected into the register slave: `INT_STATUS`'s set-vs-clear
priority inverted, so a hardware event colliding with a write-1-to-clear is
**lost**. Specification §5 requires set to win.

| | Verdict on a design that loses interrupts |
|---|---|
| **Simulation** — 3 directed benches, 5 random seeds, **4,576 checks**, 23 bound assertions, every cover property | **all passed** |
| **Bounded model check** — 16 properties, depth 25 | **failed in under a second**, naming `f_set_beats_clear_0` |

Not "formal is rigorous" in the abstract. One rule in this specification, which
this testbench cannot reach *by construction* — the collision happens inside a
single transaction, and the scoreboard compares values across whole transactions,
so no number of seeds reaches it. `axi_int_status_seq` says so in writing and
declines to claim it. [formal_notes.md](docs/formal_notes.md).

## What the testbench found

**Ten bugs. Six injected deliberately to prove the environment works — all six
caught by the mechanism the specification assigned each one, before any of those
mechanisms existed. Four genuine, and all four in the testbench rather than the
design.**

- **A cover point that could not fail to be covered.** The property meant to
  prove the driver's threads run independently was satisfied by *any*
  multi-transaction run. Qualifying it dropped the hit count from **10 to 1** on
  identical stimulus. ([BUG-007](docs/bug_reports/BUG-007.md))
- **An assertion that failed on correct hardware.** Its timing window assumed a
  delay the *master* controls and the spec does not bound. Found by random
  traffic on its first run, and unreachable by every directed test that existed.
  ([BUG-008](docs/bug_reports/BUG-008.md))
- **A driver race that passed for eleven days on timing luck**, through 44
  directed checks and 166 random transactions, until a second DUT shifted the
  schedule. ([BUG-009](docs/bug_reports/BUG-009.md))
- **Two constraints written in a form the LRM grammar does not permit.**
  `soft (a) -> b dist {...}` selects the wrong production of IEEE 1800-2017's
  constraint grammar. Xcelium accepts it; every number this project had published
  came through it. Found by pointing a second, conformant front end at the
  existing sources — in 0.2 seconds.
  ([BUG-010](docs/bug_reports/BUG-010.md))
- **Two contradictions in the frozen specification**, found while deriving the
  architecture on paper, before any RTL existed. Both fixed in the document
  first. ([dut_spec.md §10](docs/dut_spec.md))

Three results from the injected bugs are worth more than the detections
themselves:

- Injecting a real defect and removing **one stimulus case** left a correct,
  bound assertion silent while **31 of 31 checks passed** on a broken design.
  ([BUG-002](docs/bug_reports/BUG-002.md))
- A protocol violation injected into the driver passed **every functional check
  with `UVM_ERROR: 0`**. Functional correctness and protocol compliance are
  independent properties. ([BUG-001](docs/bug_reports/BUG-001.md))
- The interconnect decode injection was caught by the directed test **and
  independently by random traffic on the first seed**, which knows the map's
  shape but not where its boundaries are. ([BUG-005](docs/bug_reports/BUG-005.md))

## Results

All measured. Regenerate with `make all`.

| Metric | Value |
|---|---|
| **Local regression** | 16 runs, **9,044 checks**, parallel, **12 seconds**. `make regression` |
| **Non-UVM benches** | `sanity_tb` 31 · `sanity_mem_tb` 27 · `sanity_sys_tb` 36 · `sanity_rand_tb` ~890/seed × 10 seeds |
| **Cover properties** | **14 of 14 non-zero.** Five of them read 0 in every run this project made until the interconnect and the seeded random bench existed — closed locally, under Verilator |
| **Functional coverage** | 11 groups + 4 crosses, all modelled, sampled from observation. Per-run tables in [coverage_report.md](docs/coverage_report.md) |
| **Traceability** | 29 features → test → result, generated from the *specification's* feature list so an unclaimed feature shows as `UNCOVERED`. [traceability.md](docs/traceability.md) |
| **Formal** | 16 safety properties, PASSED at depth 25 and 40, with a cover pass proving none of them is vacuous |
| **Elaboration** | 8 UVM bundles, 0 errors, under a second. `make elab` |
| **Bugs** | 6 injected, all caught by their assigned mechanism · 4 genuine, all in the testbench. [bug_reports/](docs/bug_reports/) |
| **LLM triage** | **4/6 correct, 2/6 partial, 0/6 wrong** — and the two earlier measurements that were invalid. [llm_triage.md](docs/llm_triage.md) |

**Read the coverage narrowly.** Some cover points are zero at the slave ports and
must stay that way — `DECERR` at a slave port would be a defect, not coverage.
Which zeros are structural and which would be gaps is written out in
[coverage_status.md](docs/coverage_status.md).

Every response is checked against a reference model derived from the spec, fed by
a monitor that reconstructs from pins and has no access to the driver. Read data
the model **cannot** predict — `COUNTER`, `STATUS.busy`, `INT_STATUS[3]` — is
reported as skipped rather than silently passed, and the generated RAL declines
to check exactly the same four fields.

## Architecture

```
                    ╔═════════════════════════════╗
   AXI4-Lite        ║   AXI4-Lite Interconnect    ║
   Master ─────────▶║   (address decode + mux)    ║
   (UVM agent)      ╚══════╤═══════════════╤══════╝
                           │               │
                  0x0000_0000      0x0000_1000
                           │               │
                    ┌──────▼──────┐  ┌─────▼──────┐
                    │  Register   │  │   Memory   │
                    │  File Slave │  │   Slave    │
                    │RW/RO/W1C/WC │  │   1 KB     │
                    └─────────────┘  └────────────┘

              0x0000_1400 – 0x0000_1FFF → DECERR
              (an unmapped gap INSIDE what a single-bit decode
               would call memory — which is exactly why it exists)
```

The gap is the interesting part of the map. `ADDR[12]` alone routes `0x1400` to
memory, where it aliases onto word 0 of a 256-word array and is answered as if it
were valid. That is specification §9's BUG-005 injection, and the decode is a
range comparison because of it.

## Verification environment

```
                        uvm_test
                           │
                       axi_env
        ┌──────────────┬────┴─────┬──────────────┐
        │              │          │              │
  axi_master_agent  scoreboard  coverage     axi_reg_block
   ┌────┴────┐      (ref model) (11 groups)     (RAL)
   │sequencer│           ▲          ▲              │
   │ driver  │◀───── reg_adapter ───┼──────────────┘
   │ monitor │───────────┴──────────┘
   └────┬────┘        analysis port + uvm_reg_predictor
        │
    axi4lite_if ──── axi4lite_protocol_checker (SVA, bound ×3)
        │
   interconnect ──▶ reg slave, mem slave
```

**Driver:** one thread per AXI channel (`fork … join_none`), not a sequential
FSM. AW and W are independent channels; driving them in lockstep would never
exercise W-before-AW and would hide slave-side ordering bugs. `item_done()` fires
on **acceptance**, not completion, so a read can overlap a write — which
specification §1 permits and which `STATUS.busy` requires to be observable at
all.

**Monitor:** fully passive, no handle to the driver, reconstructs from pins only.
It also counts the cycle-level timing the three newest covergroups need, and
watches `ARESETn` so a transaction reset takes away is *counted* rather than
silently dropped.

**RAL:** generated from `scripts/regmap.yaml`, and its mirror is updated by a
`uvm_reg_predictor` on the monitor's analysis port — **explicit prediction, not
auto-predict**. A mirror fed by the operation the sequence issued agrees with the
sequence; one fed by the pins is evidence.

**Three checker instances** on a system build: the interconnect as a slave from
the master's side, and as a master from each slave's side.

## The flow

```bash
make setup        # one-time: slang, yosys, z3, UVM 1.2 source
make all          # everything that needs no person
```

| | |
|---|---|
| `make elab` | Elaborate the UVM testbench locally with slang — the same bytes that get pasted |
| `make lint` | Verilator `-Wall` on the RTL |
| `make test` | Three directed benches, all assertions live |
| `make regression` | 16 runs, parallel, multi-seed, `results.json`, non-zero exit |
| `make triage` | Clusters, new-since-last-run, flaky, not-run |
| `make coverage` | Cover properties per instance + the UVM tally, with a trend |
| `make vplan` | Feature → test → result matrix |
| `make formal` | Bounded model check |
| `make regmap` | `regmap.yaml` → RTL package + RAL + docs |
| `make playground PLAY=proto` | Bundle the UVM environment for EDA Playground (`proto` \| `reg` \| `ral` \| `rand`) |
| `make import-log LOG=…` | Bring a Playground log back in |

**There is exactly one manual step in the whole flow, and it is a property of the
tools rather than of the flow:** no free simulator runs UVM. Icarus and Verilator
have no UVM support, so the environment runs on Xcelium via EDA Playground —
two panes, pasted by hand.

Everything is built around minimising that. The thirteen directed scenarios are
written as **sequences** with thin test wrappers, so many run inside one
simulation; the seed arrives as a define because Playground's command line is
fixed; and eight random seeds run inside a single job.

Playground also caps each pane at **100,000 characters**. The environment plus
all thirteen scenarios is 133,000 with every comment already stripped, so it
cannot fit however it is arranged. The bundles are therefore split by what the
tests are *about* — protocol/decode, register semantics, RAL, random — which at
least makes the split mean something. `make playground` strips comments from the
generated bundle and **fails loudly** if a pane still exceeds the limit, so this
can never regress silently.

**Sixteen tests and eight seeds cost four pastes, sharing one design pane** — and
`make elab` means none of the four is ever spent on a typo.

## Key design decisions

Each is a deliberate scope choice, recorded so it is never mistaken for an
oversight.

| Decision | Rationale |
|---|---|
| AXI4-Lite, not full AXI | Establish methodology before protocol complexity. Bursts and IDs are a planned extension. |
| One outstanding read + one outstanding write | Keeps reorder buffers and response queues out of scope — and makes the interconnect's held-W buffer provably one entry. |
| `COUNTER` is 16-bit, not 32-bit | A 32-bit counter overflows after ~43 s of simulated time; the overflow event would be dead code and its coverage bin would never close. 16 bits wraps in 65,536 cycles, which `axi_counter_seq` reaches. |
| `STATUS.busy` covers the write path only | If it covered reads, reading `STATUS` would itself be an in-flight read and the bit could never read 0. |
| `BVALID`/`RVALID` assert no earlier than one cycle after their accepts | Registered slave. AMBA permits same-cycle for a combinational slave; excluded here so the checker can use registered pending-flags. |
| Unmapped gap at `0x1400`–`0x1FFF` | Makes the address decode non-trivial and the `DECERR` path reachable from a plausible-looking address. |
| The register map is generated; the register *behaviour* is not | W1C set-beats-clear, `CTRL[1]`'s self-clearing pulse, `STATUS.error`'s transparency rule and `COUNTER`'s priority are a spec paragraph each. A template would be a worse expression of them than an `always_ff` that cites the paragraph. |
| The scoreboard is **not** generated from `regmap.yaml` | A reference model sharing constants with the design agrees with the design by construction — which is what BUG-007 was. |

## Two tracks, one repository

| Track | What it is | Where |
|---|---|---|
| **Verification** | UVM environment, SVA checker, scoreboard, coverage model, RAL, formal | `rtl/`, `tb/`, `formal/`, [verification_plan.md](docs/verification_plan.md) |
| **Flow automation** | Regression runner, log parser with failure signatures, triage, register generator, coverage and vplan reporting, measured LLM assist | `scripts/`, [automation_plan.md](docs/automation_plan.md) |

The automation is not a side project. Once there are more than a handful of tests
and multiple seeds, running by hand stops being viable — coverage closure is only
reachable through the regression flow, and the register bank, the RAL model and
the register documentation are generated from one YAML source so they cannot
drift apart.

**The toolkit found three defects in the flow it automates**, which is the
argument for building it: parallel runs sharing a build directory, a log parser
that collapsed nine distinct failures into one signature, and a test that
disagreed with the parser about time normalisation (the parser was right).

## Repository layout

```
├── rtl/
│   ├── gen/axi4lite_reg_pkg.sv    GENERATED from scripts/regmap.yaml
│   ├── axi4lite_reg_slave.sv      8 registers, RW/RO/W1C/WC, error precedence
│   ├── axi4lite_mem_slave.sv      256 words, WSTRB byte masking
│   └── axi4lite_interconnect.sv   decode + mux, DECERR, held-W buffer
├── tb/
│   ├── interface/                 axi4lite_if.sv + protocol checker, 3 binds
│   ├── agent/                     transaction, sequencer, driver, monitor, agent
│   ├── ral/                       axi_reg_block.sv (GENERATED) + adapter
│   ├── sequences/                 base, smoke, random, memory + 13 directed,
│   │                              split to fit Playground's pane limit
│   ├── env/                       env, scoreboard, coverage collector
│   ├── tests/                     16 tests + 4 grouped runners + 3 tops
│   └── sanity_*.sv                4 non-UVM benches, incl. seeded random
├── formal/                        BMC properties + the Yosys/z3 flow
├── scripts/                       the toolkit: T1–T6, A1, elab, regmap
├── docs/                          spec, plan, architecture, 10 bug reports
└── Makefile
```

## Documentation

**Start here:** [project walkthrough](docs/project_walkthrough.md) — the whole
project explained from zero, including every bug and what it taught.

| | |
|---|---|
| [DUT specification](docs/dut_spec.md) | Source of truth; §10 is the revision history with a test per revision |
| [Verification plan](docs/verification_plan.md) | Features F01–F29, coverage model, test list, and §9's resolved open questions |
| [Traceability matrix](docs/traceability.md) | **Generated** — feature → test → result |
| [Coverage status](docs/coverage_status.md) · [measured tables](docs/coverage_report.md) | Justifications by hand; numbers generated |
| [Formal notes](docs/formal_notes.md) | What was proved, and what Yosys could not read |
| [LLM triage](docs/llm_triage.md) | The measured hit rate, and two measurements that were invalid |
| [Bug reports](docs/bug_reports/) | 10, injected and genuine, with a "what caught what" index |
| [Tooling notes](docs/tooling_notes.md) | Six tools, measured capability, not assumed |
| [Register map](docs/register_map.md) | **Generated** from `scripts/regmap.yaml` |
| [Interconnect](docs/interconnect_architecture.md) · [register slave](docs/reg_slave_architecture.md) · [memory slave](docs/mem_slave_architecture.md) | Designed on paper before RTL |
| [UVM agent design](docs/uvm_agent_design.md) · [RAL design](docs/ral_design.md) · [UVM fundamentals](docs/uvm_fundamentals.md) | Testbench decisions and the concepts behind them |
| [Automation plan](docs/automation_plan.md) | The regression and codegen flow |
| [One-page brief](docs/one_pager.pdf) | Printable A4 summary |

## Tools

- **UVM simulation:** EDA Playground with **Cadence Xcelium** (CDNS-UVM-1.2).
  Aldec Riviera-PRO compiles UVM there but cannot simulate it — the free
  entitlement excludes class-based simulation. Measured; see
  [tooling notes](docs/tooling_notes.md).
- **Elaboration:** **slang 11.0** — the whole UVM environment, locally, in 0.2 s
- **RTL simulation and SVA:** Verilator 5.050 · **Formal:** Yosys 0.68 + Z3
- **Flow:** Make + Python (regression, parsing, code generation)
- **Version control:** Git

## References

- ARM AMBA AXI Protocol Specification (AXI4-Lite chapter)
- IEEE 1800-2017 SystemVerilog LRM · UVM 1.2 / IEEE 1800.2
- OpenHW Group `core-v-verif` — referenced for verification-plan structure and
  bug-tracking practice
