# Formal experiment — measured

**Tools:** Yosys 0.68 + `yosys-smtbmc` + Z3 5.1.0, all from Homebrew.
**Flow:** [`formal/run_formal.sh`](../formal/run_formal.sh) · **Properties:**
[`formal/axi4lite_reg_slave_formal.svh`](../formal/axi4lite_reg_slave_formal.svh)

```bash
make formal
```

---

## The result that justifies the milestone

`docs/dut_spec.md` §5 states a rule that no test in this environment can decide:

> **Set-vs-clear collision:** if an event sets bit *n* on the same cycle a write
> would clear it, **set wins**. The event is real and must not be lost.

It is a *same-cycle* rule. A transaction-level sequence sees transactions, not
clock edges, and cannot place an event and a W1C write on one edge on purpose —
`tb/sequences/axi_directed_seqs.sv` says exactly that in `axi_int_status_seq`,
proves the reachable half, and declines to claim the rest.

So the priority was inverted in the RTL — `if (clear) … else if (set)` instead of
`if (set) … else if (clear)` — and both flows were run against it.

| | Result on a design that loses interrupts |
|---|---|
| **Simulation** — 3 directed benches + 5 random seeds, **4,576 checks**, 23 bound SVA assertions, all cover properties | **all passed** |
| **Bounded model check** — 16 properties, depth 25 | **failed in under a second**, naming `f_set_beats_clear_0` |

That is the entire argument for the experiment. Not "formal is rigorous" in the
abstract: one specific rule in this specification, which this testbench cannot
reach by construction, and which a proof decides immediately.

The reason simulation cannot reach it is structural, not a stimulus gap. The
scoreboard models `INT_STATUS` at transaction level, so it can only compare
before-and-after values across a whole transaction; the collision happens inside
one. Adding seeds does not help. Adding a directed test does not help. The check
has to be about a clock edge, and only one of the two flows works in those units.

## What is proved

Sixteen properties, all safety, over a bounded window. Passing at **depth 25**
and again at **depth 40**.

| Property | Spec | Why it is here |
|---|---|---|
| `f_set_beats_clear_[0-3]` | §5 | **The one above.** Same-cycle, undecidable in simulation |
| `f_w1c_keeps_[0-3]` | §5 | Writing 0 to a set bit leaves it set — the spec's own `4'b1011` / `4'b0011` → `4'b1000` example, generalised over every reachable value rather than checked at one |
| `f_w1c_no_spurious_set` | §5 | A bit that was clear, with no event, stays clear. Without it, a register that sets bits on its own satisfies everything above |
| `f_reset_stats_wins` | §5 | `reset_stats` clears `COUNTER` with **priority** over increment — the second same-cycle rule, and the second one `axi_counter_seq` explicitly cannot decide |
| `f_counter_holds` | §5 | The counter does not move when disabled |
| `f_counter_steps_by_one` | §5 | And moves by exactly one when it does |
| `f_ro_write_no_effect` | §5 | A write to `STATUS`, `COUNTER` or `ID` changes no other register |
| `f_config_reserved`, `f_int_en_reserved`, `f_ctrl_reserved` | §5, F13 | Reserved bits read 0. Structural today; this checks every future version |
| `f_reset_stats_reads_0` | §5 v0.3 | `CTRL[1]` never reads 1 |
| `f_bvalid_needs_both` | §3 rule 5 | BUG-002's rule. Also a bound SVA assertion — repeated because a proof says something stronger: simulation says *the stimulus we ran never violated this*, a BMC says *no reachable state within N cycles violates it* |

## The cover pass, which is the half people skip

An assertion that is never reached passes trivially, and a set of them will all
pass on a design that does nothing. So every run also checks that the interesting
states are **reachable** within the bound:

```
Reached cover statement in step 3: fc_collision
Reached cover statement in step 3: fc_set
Reached cover statement in step 3: fc_w1c
Reached cover statement in step 3: fc_rst_pulse
Reached cover statement in step 4: fc_counting
Status: PASSED
```

`fc_collision` is the load-bearing one. It is the same-cycle event-and-clear
itself, reached at step 3. Without it, `f_set_beats_clear_*` could be passing
because nothing can ever produce the collision — and the file would be
decoration.

## What Yosys could not read

This half is a finding too, in the same register as *"Riviera compiles UVM and
cannot simulate it"* in [tooling_notes.md](tooling_notes.md).

**Yosys's open-source frontend supports no concurrent SVA at all.** Every form
below was tried against Yosys 0.68 and rejected:

| Written | Yosys |
|---|---|
| `default clocking @(posedge ACLK); endclocking` | `ERROR: syntax error, unexpected TOK_DEFAULT` |
| `assert property (@(posedge ACLK) disable iff (!rst) a \|=> b);` | `ERROR: syntax error, unexpected '@'` |
| `assert (a \|=> b);` | `ERROR: syntax error, unexpected TOK_BIT_OR_ASSIGN` |
| `property pr; … endproperty` | `ERROR: syntax error, unexpected TOK_PROPERTY` |
| `import pkg::*;` *inside a module* | `ERROR: syntax error, unexpected TOK_IMPORT` |
| a wrapper module referencing `dut.int_status_q` | `ERROR: Identifier `\dut.int_status_q' is implicitly declared` |
| `bind` | no support |

What it *does* accept in `-formal` mode is the **immediate** assertion inside a
clocked `always` block, plus `$past`. So every property is written as
`assert (consequent)` guarded by the antecedent held for one cycle in an explicit
history register.

Four consequences, each of which cost time and is worth writing down:

1. **The 23 SVA assertions in `tb/interface/axi4lite_if.sv` cannot be reused.**
   They use `##[0:8]` windows and `$stable`, neither of which Yosys reads.
   Rewriting all of them in this subset would be a second checker to keep
   correct, so only the rules worth the duplication were rewritten.

2. **The properties live inside the DUT**, under `` `ifdef FORMAL ``, because
   Yosys resolves neither hierarchical references nor `bind` and there is
   nowhere else for a property about internal state to go. Verilator, Icarus,
   slang and Xcelium never define `FORMAL`, so nothing they compile changes.

3. **The package import moved out of the module** — not to a `$unit` import,
   which Verilator warns about (`IMPORTSTAR`), but to explicit
   `axi4lite_reg_pkg::` references aliased once at the top of the module.
   Neither wildcard form is portable across the four tools. The alternative —
   preprocessing the source for the formal flow — was rejected because it would
   mean the proof is about a *derived copy* of the design rather than about the
   design.

4. **`async2sync; dffunmap` is required before `write_smt2`.** Spec §1 specifies
   an asynchronous reset assert, so the RTL infers `$adff` cells, which
   `write_smt2` cannot model. The rewrite is sound *here* because of the other
   half of the same contract — §1 also requires the testbench to deassert
   `ARESETn` only on an active clock edge, so the design never sees reset change
   between edges. A design with a genuinely asynchronous release would need
   `clk2fflogic` and a much slower proof.

## Two mistakes in the harness, and what they looked like

Both produced failures that were about the *proof setup*, not the design, and
both are the kind that would be reported upward as RTL bugs by someone who did
not look.

**Formal starts in an arbitrary state, not a reset one.** The first run reported
four failures at step 0 — registers that had "changed" from values they never
held, because the history registers began holding whatever the solver liked. Two
lines fix it: an initial value on `f_init`, and `if (!f_init) assume (!ARESETn)`.

**`rd_idx` follows the current address, not the pending read's.** The register
slave has no read-address latch — `ARREADY` is gated on `!rvalid_q`, so the
response is computed straight from `ARADDR` on the accept cycle. A property
correlating `RDATA` with `rd_idx` therefore compares this cycle's address against
a previous cycle's data. It needed its own capture register. The property was
wrong; the RTL was not.

## Scope

This is **not** a proof of the design. It is a proof of sixteen safety rules
about one slave's internal state, over a bounded window of 25–40 cycles.

Not attempted, and named so their absence is not mistaken for a result:
unbounded proof (`k`-induction), the memory slave, the interconnect, and any
liveness property. The interconnect in particular would be the interesting next
target — its held-W buffer is exactly the kind of one-entry state machine a
bounded model check is good at — and the response-ordering rules in
`axi4lite_if.sv` would have to be rewritten in this subset first.

## Reproducing

```bash
make setup      # brew install yosys z3
make formal     # depth 25
./formal/run_formal.sh 40
```

The proof runs in about two seconds at depth 25 and six at depth 40.
