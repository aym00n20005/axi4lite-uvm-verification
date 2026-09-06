# LLM-assisted triage — measured

**Automation plan A1.** The tool is `scripts/llm_triage.py`; the measurement is
this document, and the measurement is the deliverable.

`docs/automation_plan.md` §3 set the terms before anything was built:

> *Every student at DVCon 2026 will say "I used AI." The program itself has a
> counter-theme asking who verifies the AI-written verifier. Claiming without
> measuring is how you lose the conversation.*
>
> *Don't ship the AI layer without the measurement. Unmeasured, it's the weakest
> thing in your repo. Measured, it's among the strongest.*

---

## The result

**4 of 6 correct, 2 of 6 partial, 0 of 6 wrong.**

Fed nothing but a failure signature and a log excerpt, a model named the actual
root cause of four of the six deliberately injected bugs, and got the right
component with the wrong mechanism on the other two. It was never wrong in a way
that would have sent someone to the wrong file.

Reproduce it:

```bash
python3 scripts/llm_triage.py --measure --backend replay
```

`replay` reads the committed responses in `results/llm_cache/`, so the number
above is reproducible by anyone who clones the repo. `--backend claude-cli`
re-asks the model and will produce different wording.

## What it was given, and what it was not

| Given | Withheld |
|---|---|
| The normalised failure signature | The RTL, the testbench, any source file |
| A log excerpt (10–20 lines) | The bug report naming the root cause |
| One sentence of context about the DUT | The fact that a bug was injected at all |

The six bugs are `docs/dut_spec.md` §9's qualification set. Each root cause was
written down in `docs/bug_reports/` before this script existed, so the answer key
was fixed in advance.

## Per bug

| Bug | Signature | Verdict | What it said |
|---|---|---|---|
| BUG-001 | `ASSERT:a_awvalid_stable` | **correct** | "the AXI **master driver**'s write-address phase drives AWVALID for a fixed single cycle instead of holding it until AWREADY is sampled high" — and attributing it to the master rather than the slave is the whole point of this injection |
| BUG-002 | `ASSERT:a_bvalid_not_early` | **correct** | "drives BVALID off a single handshake (AW accepted, or an OR of AW/W) instead of requiring both AW and W to have completed" |
| BUG-003 | `UVM:SB:RDATA mismatch` | *partial* | Named WSTRB and per-byte-lane qualification — right area, right next step — but described the mechanism **backwards**: it said the partial writes were "dropped entirely" when in fact all four bytes were written |
| BUG-004 | `UVM:uvm_reg_bit_bash_seq` | **correct** | "the RTL write path stores/sets the data instead of clearing… **or a plain RW load**" |
| BUG-005 | `CHECK:write <H> -> DECERR` | *partial* | Claimed the DECERR path was "response-only" — but the log shows no DECERR was returned at all. Its *next step*, "confirm the memory slave's hit uses the full compare against 0x1000–0x13FF rather than a lower-bound-only or **bit-sliced compare**", is the defect exactly |
| BUG-006 | `CHECK:COUNTER reads exactly <N>` | **correct** | "the counter-clear is gated by CTRL.enable… so `CTRL=0x2` leaves the counter holding its stale value" — a concrete mechanism for the recorded defect |

## Where it is good and where it is not

**Good at:** naming the component and the channel. All six answers pointed at the
right file, and BUG-001's answer correctly blamed the *master* rather than the
slave — which is the distinction that whole injection exists to test, and the one
`dut_spec.md` §10 records getting wrong in v0.1 of the spec itself.

**Unreliable at:** reading the numbers. Both partial answers describe a plausible
mechanism that the log data contradicts. BUG-003's excerpt shows bytes that were
overwritten; the model said they were preserved. BUG-005's excerpt shows `0x0`
where `0x3` was expected; the model said `DECERR` was returned.

**The honest one-liner:** *it is good at grouping and localising, and it invents
a plausible mechanism about a third of the time — one the waveform contradicts.
Its next step is worth reading even when its root cause is wrong.*

## Two measurements that were invalid, and why they are recorded here

A number produced by a broken harness is worse than no number, because it looks
like rigour. Both of these were caught before publication and both are recorded
because the second one in particular is easy to repeat.

### 1. The model could read the repository — scored 5/6, meaningless

The first run invoked the CLI in the project directory. The model read the
source. Its BUG-005 answer cited `rtl/axi4lite_interconnect.sv:152`; its BUG-004
answer opened with *"Checked the RTL and RAL in the repo"*.

That is not triage, it is looking up the answer, and the score measured file
access rather than inference. The backend is now sealed: an empty working
directory, `--disallowedTools` covering every file, search and execution tool,
and `--permission-mode plan`. Belt and braces, because any one of them leaking
would silently inflate the score.

### 2. The scorer graded the whole answer — scored 5/6, too generous

With the model sealed, the mechanical scorer still returned 5/6. Reading the
answers by hand gave 4/6. The disagreement was BUG-005: its **root cause** was
wrong, and it scored `correct` because the phrase "bit-sliced compare" appeared
in its **next step**.

A triage note's next step is a suggestion; its root cause is a claim. Only the
claim is what the tool is being measured on, so `score()` now grades the root
cause line alone. The mechanical number and the hand review then agree at 4/6.

## How it is scored

Mechanically, by keyword, against the recorded root cause — never by a person's
impression and never by another model. A score that depends on who reads it is
not a measurement, and a model grading a model is the thing this exercise exists
to avoid.

The keywords are coarse. That is stated rather than hidden: the mechanical score
is *reproducible*, the hand review is *right*, and where they disagreed the
disagreement is written down above. Publishing only the flattering one is the
failure §3 warns about.

## How it is used

Advisory. `triage.py --llm` annotates a cluster; it never decides anything, never
files a bug, and never suppresses a failure. It is off by default.

The claim this project makes about it is the measured one and nothing more:

> *"I use it to cluster and summarise, and I measured how often it's right. It's
> good at localising a failure to a component and unreliable at the mechanism —
> about a third of the time it invents a plausible cause that the log data
> contradicts."*

Which is, almost word for word, the framing `automation_plan.md` §3 predicted
would be the honest one — arrived at by measuring rather than by guessing that it
would be.
