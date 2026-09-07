# RAL — design decisions

**Model:** [`tb/ral/axi_reg_block.sv`](../tb/ral/axi_reg_block.sv) — *generated*
from [`scripts/regmap.yaml`](../scripts/regmap.yaml) by `make regmap`.
**Adapter and predictor:** [`tb/ral/axi_reg_adapter.sv`](../tb/ral/axi_reg_adapter.sv),
wired in [`tb/env/axi_env.sv`](../tb/env/axi_env.sv).

---

## 1. What the RAL is actually for here

Not saving typing. The access policy is stated **once**, in the YAML, and then
checked against the DUT by library code — `uvm_reg_hw_reset_seq` and
`uvm_reg_bit_bash_seq` — that has never read this project's specification.

A hand-written access-policy test beside a hand-written register bank is two
transcriptions of one table by one person, and they agree with each other's
mistakes. That is the entire argument, and [BUG-004](bug_reports/BUG-004.md) is
the evidence: `INT_STATUS` injected as a plain RW register, caught by `bit_bash`
with **nobody having written a test for it**.

`bit_bash` also covers **F13 for free**, which is worth knowing rather than
rediscovering. `uvm_reg_single_bit_bash_seq` treats any bit no field claims as
`"RO"`, so a reserved bit that stored data fails there without a reserved-bit
test existing.

## 2. Explicit prediction, not auto-predict

UVM offers two ways to keep the mirror current:

| | Mirror updated from | Cost |
|---|---|---|
| **auto-predict** | the operation the sequence issued | free |
| **explicit** | the **monitor's** analysis port, via `uvm_reg_predictor` | a predictor and one `connect_phase` line |

This environment uses **explicit**, and the reason is the one that shaped the
monitor: a model fed by the stimulus agrees with the stimulus. If the driver
dropped a write, auto-predict would update the mirror anyway, the next read would
be compared against a value the DUT was never told to hold, and the failure would
be reported against the **DUT**.

```systemverilog
regmodel.axi_map.set_auto_predict(0);   // the predictor is the only writer
predictor.map     = regmodel.axi_map;
predictor.adapter = adapter;
agent.mon.ap.connect(predictor.bus_in);
```

Turning auto-predict off is not optional here. Leaving both on gives the mirror
two sources and a double update on every access.

**Frontdoor only.** No backdoor is configured: a backdoor write proves nothing
about the bus, and the bus is what is being verified.

## 3. The one driver change the RAL required

`uvm_reg_map::do_bus_write` reads the response **straight out of the request
item** as soon as `finish_item` returns, because the adapter declares
`provides_responses = 0`. And `finish_item` returns when the driver calls
`item_done` — which this driver does at **acceptance**, deliberately, so a read
can overlap a write and F24 (`STATUS.busy`) is observable at all.

For ordinary traffic that is exactly right: the sequence owns the handle and
waits on `t.completed` itself.

For a RAL access it is wrong in a way that would not announce itself. The RAL
would read `resp` before the B channel had written it, report `UVM_IS_OK` for
every access including the failing ones, and **a `bit_bash` run against a broken
access policy would pass**.

So `axi_reg_adapter::reg2bus` sets `t.from_ral`, and `axi_driver::dispatch` holds
`item_done` for that one item until the bus has answered:

```systemverilog
if (t.from_ral) wait (t.completed == 1'b1);
```

The cost is that RAL accesses do not overlap — which they must not anyway. A
mirror updated from a read that overtook its own write is not a mirror.

## 4. WSTRB on RAL writes is always `4'b1111`

Not laziness. Specification §5: any strobe other than all-ones on a register
write is `SLVERR` with the register unchanged. A RAL frontdoor write is a
*request to change a register*, so anything but a full strobe would make every
`uvm_reg::write()` fail by construction — including `bit_bash`'s, which would
then report an access-policy defect on a correct DUT.

Partial-strobe register writes are F16 and belong to a directed test that means
them: `axi_reg_strobe_seq`.

## 5. Access types, and the two that are not obvious

Four are supported. `regmap_gen.py` rejects anything else rather than guessing —
adding a fifth means deciding what the RTL, the RAL and the documentation each do
with it, which is three decisions rather than one.

| Field | Access | Why |
|---|---|---|
| `CTRL.enable` | `RW` | plain storage |
| **`CTRL.reset_stats`** | **`WC`** | A self-clearing command bit: writing 1 clears `COUNTER`, and the bit itself **always reads 0**. `dut_spec.md` §5 warns about exactly this: *"the RAL model must declare `CTRL[1]` accordingly — it is not a plain RW bit and `bit_bash` will flag it if modelled as one."* UVM's `WC` predicts `'0` on any write, which is what the DUT does. |
| `CONFIG.cfg`, `INT_ENABLE.en`, `SCRATCH.value` | `RW` | plain storage |
| **`INT_STATUS[3:0]`** | **`W1C`** | `cur_val & ~wr_val`. This is the prediction that catches BUG-004. |
| `STATUS.busy`, `STATUS.error`, `COUNTER.count`, `ID.id` | `RO` | writes accepted with `OKAY`, discarded |

## 6. The four fields the RAL declines to check

Hardware writes them, so the mirror can legitimately disagree with the DUT and a
comparison would be a **false failure rather than a detection**.

| Field | `set_compare(UVM_NO_CHECK)` because | Scoreboard does the same at |
|---|---|---|
| `STATUS.busy` | cycle-level state | mask `32'hFFFF_FFFE` |
| `STATUS.error` | hardware writes it on every completed transaction, except a read of `STATUS` itself — a rule the RAL has no way to express | the scoreboard *can* express it, and does |
| `COUNTER.count` | free-running while `CTRL.enable` | checked only in the cleared-and-frozen state |
| `INT_STATUS[3]` | follows `COUNTER` | mask `32'hFFFF_FFF7` |

**They are masked in exactly the places the scoreboard masks them**, which is the
point of listing them together: two independently written models make the *same
claim* about what is knowable from transactions alone. If they disagreed, one of
them would be wrong.

`INT_STATUS[2:0]` keeps its comparison. That comparison is what catches BUG-004,
and dropping it "for safety" would have removed the only mechanism §9 assigns to
that injection.

## 7. Sequence order, and why it is not arbitrary

```
hw_reset  →  bit_bash  →  explicit policy checks
```

- **`hw_reset` first.** It reads every register and compares against its declared
  reset value — the only check whose expectation is destroyed by any other
  traffic.
- **`bit_bash` second.** It sets `CTRL.enable` along the way, which starts
  `COUNTER` running. That is harmless because `COUNTER` is `UVM_NO_CHECK`, and it
  is why it is second rather than first.
- **Explicit checks last**, stated in the specification's own terms, so a failure
  names the rule rather than a bit index.

## 8. What is not modelled

| Not done | Why |
|---|---|
| Backdoor access | Proves nothing about the bus |
| Register coverage (`UVM_CVR_*`) | The functional coverage model already samples every register offset and access class from the monitor. A second, independent count would be duplication rather than corroboration — unlike the scoreboard/RAL masking above, where the duplication *is* the check |
| The memory as a `uvm_mem` | 256 words of plain storage with no access policy. The scoreboard's associative-array model is a better fit and already exists |
| Multiple maps or address translation | One master port, one map |


---

## Volatile fields are not checked by the library sequences — measured

`scripts/regmap.yaml` marks `STATUS.busy`, `STATUS.error`, `COUNTER.count` and
all four `INT_STATUS` bits `volatile: true`, because hardware changes them
without a bus write. That is required: without it, `uvm_reg_hw_reset_seq` and
every `mirror()` would report false failures whenever the DUT set a bit between
the model's write and its read.

**It has a consequence that is not obvious from the RAL API**, and this project
found it by running the BUG-004 injection rather than by reading:

```systemverilog
// uvm_reg_field.svh:818, inside configure()
m_check = volatile ? UVM_NO_CHECK : UVM_CHECK;
```

```systemverilog
// uvm_reg_bit_bash_seq.svh, building the don't-care mask
dc = (fields[k].get_compare() == UVM_NO_CHECK);
...
if (dc_mask[k]) continue;          // the bit is never bashed
```

Declaring a field volatile turns off its comparison **everywhere**, so
`bit_bash` skips it and `hw_reset` (which checks via `mirror(UVM_CHECK)`) skips
it too. The access policy of a volatile field is never verified by the RAL.

For this register map that means the RAL does real, unforgeable work on the
seven non-volatile registers, and **no access-policy work at all on
`INT_STATUS`** — the one register whose access policy is the most interesting
thing about it.

`INT_STATUS`'s W1C semantics are therefore covered by
[`axi_ral_seq`'s directed F12 block](../tb/sequences/axi_ral_seq.sv), the
scoreboard's reference model, and `f_w1c_no_spurious_set` in the formal file.
[BUG-004](bug_reports/BUG-004.md) records the measurement that established this,
including the option of selectively re-enabling compare with `set_compare()`,
which has **not** been tried.
