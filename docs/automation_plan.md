# DV Automation Toolkit — Plan

**Version 0.2 · 17 August 2026**
Companion to the AXI4-Lite UVM verification project. Same repository: this document lives in `docs/`, the code it describes lands in `scripts/`.

**Revisions**
- v0.2 (17 Aug 2026) — added §8, the listability gate and resume framing. No change to scope or schedule.
- v0.1 (12 Aug 2026) — initial plan.

---

## 0. The core decision

**Do not build a separate scripting project.** Build the flow that runs this one.

A standalone "Python automation project" reads as coursework. A regression runner, log parser and coverage tracker that you wrote *because your own testbench needed them* reads as a verification engineer. It's the same Python, but the second version has a reason to exist, and the reason is what gets discussed in an interview.

It also costs you nothing in attention. Every script below is something you would otherwise do by hand fifty times between September and December.

**Timing:** nothing here starts before 31 August. Before DVCon you write one Makefile and nothing else. The toolkit is a September–December build, running in parallel with the verification milestones it serves.

---

## 1. Language scoping — what's actually worth learning

| Language | Where it's used in EDA | Priority for you |
|---|---|---|
| **Python** | Everything written this decade — regression, parsing, reporting, code generation, CI, tool APIs | **Primary.** All new work. |
| **TCL** | Simulator, synthesis and P&R tool control. Every major EDA tool exposes a TCL console. Waveform automation, coverage commands, build scripts. | **Second.** Underrated by students, expected by employers. |
| **Makefile** | The universal front door to a verification flow. `make test TEST=smoke` is what every DV engineer types. | **Learn immediately.** Trivial and mandatory. |
| **Perl** | Legacy log parsing and flow scripts at established companies. Large existing codebases; very little new code. | **Read-only fluency.** Enough to understand and patch someone else's script. |
| **Bash** | Glue, CI, file wrangling | Basic competence |

**How to phrase this honestly at DVCon:** *"I write my flow in Python, I use TCL to drive the simulator, and I can read Perl well enough to maintain an existing script."* That's an accurate and unusually well-calibrated answer for a student. Claiming Perl expertise you don't have is the same trap as claiming UVM fluency.

---

## 2. The toolkit

Six components, ordered by how much they earn their keep.

### T1 — `Makefile` + `run_regression.py` (September)

The front door. Everything else hangs off it.

```
make test TEST=axi_smoke_test
make test TEST=axi_random_test SEED=42
make regression
make coverage
make clean
```

`run_regression.py` does:

- Read a test list from `scripts/testlist.yaml` — test name, seed count, expected result, timeout
- Launch runs in parallel (`concurrent.futures`), respecting a job limit
- Capture stdout/stderr per run into `results/<timestamp>/<test>_<seed>/`
- Write a machine-readable `results.json` and a human summary table
- Exit non-zero if anything failed, so CI can use it

**Why it matters:** the moment you have more than four tests and multiple seeds, running by hand stops being viable. This is the script that makes coverage closure possible at all.

**Skills demonstrated:** subprocess management, parallelism, YAML config, structured output, exit codes.

### T2 — `parse_log.py` (September)

Simulator logs are thousands of lines. This turns one into a verdict.

- Extract `UVM_ERROR` / `UVM_FATAL` / `UVM_WARNING` counts
- Extract assertion failures with the assertion name, time, and file/line
- Extract the scoreboard mismatch (expected vs actual, address, transaction)
- Produce a **failure signature** — a normalised string like `ASSERT:a_bvalid_not_early` or `SCOREBOARD:mem_data_mismatch`, with numbers and timestamps stripped so identical failures hash identically
- Emit JSON

**The failure signature is the important idea.** It's what makes T3 possible, and it's a concept most students have never encountered. Real regression triage is entirely built on it.

**Skills demonstrated:** regex, text processing, normalisation, data modelling.

### T3 — `triage.py` (October)

Takes a regression's worth of `results.json` and answers: *what actually broke?*

- Cluster failures by signature — 200 failures are usually 3 bugs
- Rank clusters by count and by how many distinct tests they touch
- Detect **new** failures by diffing against the previous run's signature set
- Flag flaky tests: same test, same code, different result across seeds
- Output a short triage report: *3 distinct failures, 1 new since last run, 1 flaky*

**Why it matters:** this is the single most valuable script in any real DV team, and almost nobody builds it at student level. "I wrote a regression triage tool that clusters failures by signature" is a sentence that will stop a DV manager mid-conversation.

### T4 — `regmap_gen.py` (October) — the differentiator

Read the register map from a single source of truth (`regmap.yaml`) and **generate**:

1. `axi4lite_reg_slave.sv` register bank — the RTL storage, decode and access-policy logic
2. `axi_reg_block.sv` — the UVM RAL model
3. `register_map.md` — documentation
4. Optionally the register-map diagram

One YAML file, four consumers, no possibility of drift between RTL, RAL and docs.

**Why this is the strongest piece:** register generation from a machine-readable spec is genuinely how the industry works — it's the entire product category that Agnisys sells into, and Agnisys is a DVCon India 2026 sponsor. Walking up to their booth and saying *"I wrote a small register generator for my own project — what do real tools handle that mine doesn't?"* is an outstanding conversation, and the answer (IP-XACT, SystemRDL, multi-view generation, field-level callbacks) is genuinely worth hearing.

It also directly serves your October RAL milestone. You'd be hand-writing that RAL model otherwise.

**Skills demonstrated:** code generation, templating (Jinja2), schema design, single-source-of-truth discipline.

**Scope warning:** generate the register bank and RAL for *your* eight registers and your four access types. Don't try to build a general-purpose tool. A generator that handles RW/RO/W1C correctly and says "unsupported access type" for anything else is honest and finishable.

### T5 — `coverage_report.py` (November)

- Parse coverage database output into structured data
- Track coverage over time — commit hash, date, per-covergroup percentages
- Generate a markdown or HTML report with a trend
- Flag bins that have been at 0% for more than N runs — those are the ones needing either new stimulus or a written justification

**Skills demonstrated:** data aggregation, reporting, plotting (`matplotlib`), historical tracking.

### T6 — `vplan_trace.py` (November) — the maturity signal

Parse the feature table in `docs/verification_plan.md` (F01–F29), and cross-reference against:

- which test claims to cover each feature
- whether that test passed in the latest regression
- which covergroup maps to it and its current percentage

Output a **traceability matrix**: feature → test → result → coverage → status.

**Why it matters:** this is what a verification lead actually reports upward. It answers "are we done?" with evidence instead of opinion. A student who has built one has understood what verification *is*, not just how to write a testbench.

---

## 3. The AI layer — do this carefully

The opportunity is real, but the failure mode is worse than not doing it. Every student at DVCon 2026 will say "I used AI." The program itself has a counter-theme asking who verifies the AI-written verifier. Claiming without measuring is how you lose the conversation.

### What's credible

**A1 — LLM-assisted failure triage (extends T3).** Feed a failure cluster's signature plus the surrounding log context to an LLM, ask for a root-cause hypothesis and a suggested next debug step. Keep it advisory — it annotates the triage report, it never decides anything.

**A2 — Covergroup skeleton generation.** Feed the vplan feature table to an LLM, get covergroup skeletons back. You review, correct and commit. Saves typing, changes nothing about who is responsible.

**A3 — Test stub generation from the vplan.** Same pattern.

### The part that makes it a result rather than a claim

**Measure it against your six injected bugs.**

You have BUG-001 through BUG-006, each with a known root cause. Run A1 on each failure and record:

- Did it identify the correct root cause? Yes / partially / no
- Did it suggest a useful next step?
- Where did it confidently say something wrong?

Then publish the hit rate in your README. If it gets 3 of 6, say 3 of 6. **A measured negative result is a far better DVCon conversation than an unmeasured positive claim**, because it means you've actually thought about the limits — which is exactly the question the industry is asking itself this year.

### What to avoid saying

- "AI-generated assertions" — the immediate follow-up is *did you verify them, and against what?*
- "AI verification agent"
- Anything implying the LLM is trusted rather than reviewed

**The honest framing:** *"I use it to cluster and summarise, and I measured how often it's right. It's good at grouping failures and unreliable at root cause — about half the time it invents a plausible cause that the waveform contradicts."*

---

## 4. Schedule

| Window | Build | Serves |
|---|---|---|
| Before 31 Aug | Nothing but a 20-line Makefile with `make test` | Keeps DVCon prep clear |
| September | T1 regression runner, T2 log parser | The interconnect + scoreboard milestone |
| October | T3 triage, T4 register generator | The RAL milestone — T4 generates it |
| **Mid-Oct** | **Gate: T1, T2 and T4 exist and run** | **The point this becomes listable — see §8** |
| November | T5 coverage reporting, T6 vplan traceability, A1 with measurement | Coverage closure + bug database |
| December | Documentation, README, clean-up | Interview readiness |

---

## 5. Repository placement

```
axi4lite-uvm-verification/
├── docs/
│   └── automation_plan.md  # this document
├── scripts/
│   ├── Makefile
│   ├── run_sim.sh          # exists — the local Icarus/Verilator flow
│   ├── run_regression.py
│   ├── parse_log.py
│   ├── triage.py
│   ├── regmap_gen.py
│   ├── coverage_report.py
│   ├── vplan_trace.py
│   ├── templates/          # Jinja2 templates for regmap_gen
│   ├── testlist.yaml
│   └── regmap.yaml         # single source of truth for the register map
└── results/                # gitignored
```

Same repo, not a separate one. The point is that the automation exists to serve the verification — splitting them destroys the story.

---

## 6. How to pitch this at DVCon

Don't lead with it. Lead with the verification project, and let this come up when they ask what your flow looks like — which they will, because it's the question that separates people who've run a regression from people who've run a simulation.

> "Right now I run tests by hand, but I'm building the flow around it in September — a regression runner with parallel seeds, a log parser that produces failure signatures so I can cluster failures instead of reading two hundred logs, and a register generator that emits both the RTL register bank and the RAL model from one YAML file so they can't drift apart."

Then the question that gets you a real conversation:

> "How does your team handle regression triage? Do you cluster by failure signature, or is there something better?"

**Booths where this is the right topic:** Agnisys (register generation — ask them directly what SystemRDL handles that a hand-rolled generator doesn't), Coverify and Verifast (verification analytics), the EDA vendors (Synopsys/Cadence/Siemens all sell regression management), and any services company — Tessolve, Mirafra, Quest Global all bill for flow and automation work, and a student who can script is immediately more useful to them.

---

## 7. What not to do

- **Don't start before 31 August.** You have 20 days and no RTL.
- **Don't build a general-purpose tool.** A register generator that handles your four access types is finishable. One that handles IP-XACT is not.
- **Don't learn Perl properly.** Read-only fluency, a weekend at most, and only once the Python is real.
- **Don't ship the AI layer without the measurement.** Unmeasured, it's the weakest thing in your repo. Measured, it's among the strongest.
- **Don't split this into a second repository.** The automation's value comes entirely from what it automates.
- **Don't list this on a resume before mid-October.** See §8.

---

## 8. Listability and framing

Two conditions govern when and how this appears outside the repo.

### Condition 1 — don't list it until it runs

Right now this is a plan document, and a plan on a resume is a liability the moment someone opens the repo. The gate is **mid-October**, when T1, T2 and T4 exist and run:

- T1 — `make regression` launches parallel multi-seed runs and writes `results.json`
- T2 — `parse_log.py` produces normalised failure signatures
- T4 — `regmap_gen.py` emits the register bank, the RAL model and `register_map.md` from `regmap.yaml`

Until all three run, the toolkit is not a resume line. It is fine for it to be visible in the repo as a plan before then — plans in `docs/` read as intent; plans on a resume read as claims.

### Condition 2 — don't present the two projects as unrelated

They share a repo. A DV manager will notice within thirty seconds of opening GitHub, and how they read it depends entirely on the framing:

- Two "separate projects" that turn out to be one repo reads as padding.
- **A verification project plus the flow that runs it reads as scope** — which is the truth, and is more impressive, because building your own regression infrastructure is what a working DV engineer does.

So: two resume entries, one repo, and the second entry says out loud that it automates the first. The README carries the same framing so the repo confirms the resume rather than contradicting it.

### What's honestly claimable, by when

| Date | Verification project | Automation toolkit |
|---|---|---|
| 31 Aug 2026 | "in progress" — agent + assertions | not listable |
| Mid-Oct 2026 | Full env, scoreboard, RAL | T1, T2, T4 — listable |
| Dec 2026 | Complete, with coverage closure | Full toolkit |

Applications open in October, so at submission time the first two toolkit bullets will likely be solid and the third in progress. **Write bullets for what exists on the day you send it**, and update them between applications rather than writing December's resume in October. Draft bullets live in `docs/resume_bullets.md` (untracked — it changes per application).

### One structural note

Two projects is right for a fresher resume. **Don't add a third.** Depth in two beats breadth in four, and this pair tells one coherent story about what kind of engineer you are.
