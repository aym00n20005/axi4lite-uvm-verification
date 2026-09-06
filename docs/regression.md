# The regression flow

```bash
make all
```

Runs elaboration, lint, the parser's own tests, the regression, triage, coverage,
the traceability matrix and the formal proof — in that order, with nobody in the
loop. Twelve seconds for the regression itself; under a minute for all of it.

---

## The one manual step, and why it exists

**No free simulator runs UVM.** Icarus and Verilator have no UVM support
([tooling_notes.md](tooling_notes.md)), so the environment runs on Cadence
Xcelium via EDA Playground — two panes, pasted into a browser by hand.

That is a property of the tools, not of the flow, and the whole design of this
regression is about minimising it rather than pretending it is not there:

| Cost | Before | Now |
|---|---|---|
| Typos | one browser round trip each | `make elab`, 0.2 s, 8 bundles |
| 16 tests | 16 pastes | the thirteen directed scenarios are **sequences**, so all fifteen run in one simulation |
| 8 random seeds | impossible — Playground's command line is fixed | the seed is a **define**, and `axi_multiseed_test` runs eight passes in one job |
| Total | ~24 pastes | **3**, and the three differ by one line |

`scripts/testlist.yaml` marks those three `runner: imported`. The regression
runner cannot launch them; it reads their **logs** instead, dropped into
`sim/logs/` by `make import-log`, and parses them with exactly the same code it
uses on a run it launched itself.

A missing imported log is reported as `MISSING` — **not** a failure and **not** a
pass. It is neither: nobody has run it. Calling that a pass is how a regression
reports green on a test that has not executed in a month.

## What each stage does

| Stage | Tool | Decides |
|---|---|---|
| `regcheck` | `check_regmap.py` | Does `regmap.yaml` still agree with `dut_spec.md` §5? |
| `elab` | slang | Does the UVM source mean what it says, in a conformant tool? |
| `lint` | Verilator `-Wall` | Is the RTL clean? |
| `test-scripts` | `test_parse_log.py` | Does the log parser everything else depends on still work? |
| `regression` | `run_regression.py` | 16 runs, 10 seeds, parallel, `results.json`, non-zero exit |
| `triage` | `triage.py` | How many *distinct* failures, which are new, which are flaky, which never ran |
| `coverage` | `coverage_report.py` | Cover counts per checker instance, the UVM tally, and a trend |
| `vplan` | `vplan_trace.py` | Feature → test → result, from the specification's list |
| `formal` | Yosys + z3 | The same-cycle rules no simulation here can decide |

## The failure signature

The idea the whole toolkit rests on. Counting `UVM_ERROR`s tells you a run
failed; it does not tell you whether two hundred failures are two hundred bugs or
three.

A signature is a normalised string — every address, cycle number, timestamp, seed
and instance index replaced by a token — so the same defect produces the same
string from every run that hits it:

```
SCOREBOARD:RDATA_mismatch
ASSERT:a_bvalid_not_early
WATCHDOG:no bus activity for <T>
CHECK:write <H> -> DECERR
```

Normalisation has to be right in both directions. Too aggressive and two
different bugs collapse into one cluster; too little and one bug appears once per
seed. `scripts/test_parse_log.py` checks both — every case asserts the signature
that *should* appear and, where it matters, one that should **not**.

**Demonstrated on BUG-005:** a single-bit interconnect decode produced 952 failing
checks across 11 runs, which triage reduced to **13 distinct failures**, three of
which accounted for thirty of the thirty-three failing random-seed results.

## Three defects the toolkit found in the flow it automates

Worth recording, because they are the argument for building it rather than
running tests by hand.

1. **`run_regression.py`'s first real use reported 5 of 10 seeds `INCOMPLETE`.**
   Ten parallel runs of one top were all building into the same directory, each
   starting with `rm -rf`. Splitting build from run fixed it *and* took the local
   regression from 90 seconds to 11 — compiling once is what a regression should
   do anyway, since the binary does not depend on the seed.

2. **`parse_log.py`'s first version collapsed nine distinct failures into
   `CHECK:read`.** A lazy match stopped at the first `0x` in the line, and half
   these check names contain an address. Its second version missed 75
   random-traffic failures entirely, because the pattern was anchored on a value
   column that bench does not print.

3. **`test_parse_log.py` disagreed with the parser** about whether `20000 ns`
   normalises to a time or a number. The parser was right — a duration is a time,
   and collapsing watchdog trips at any limit into one signature is correct — so
   the test was changed.

## Reading the output

```
       test                      seed      checks     time  signatures
  ---- ------------------------ -----  ----------  -------  --------------
  ok   sanity_rand_tb               7     897/897     0.8s
  --   axi_regression_test                      -        -
       not run yet -- make playground PLAY=sys, paste, run, then
       make import-log LOG=sim/logs/sys.log TEST=axi_regression_test

  16 runs in 11.6s: 3 MISSING, 13 PASS
  9044/9044 checks passed
```

`triage.py` then answers the question that output does not:

```
  13 runs, 2 passed, 11 failed.
  952 failing checks are 13 distinct failures, 13 new since 20260907_034533.
```

## Adding a test

One entry in `scripts/testlist.yaml`. The `features:` list is read by
`vplan_trace.py` as well, so a test's claim about what it covers is written once
rather than in a comment in one file and a table in another — and a feature that
nothing claims shows up in [traceability.md](traceability.md) as `UNCOVERED`
with an empty test column.
