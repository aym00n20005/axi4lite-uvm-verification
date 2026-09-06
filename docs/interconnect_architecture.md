# Interconnect — architecture

**Implements** `docs/dut_spec.md` v0.3 §7, decoding per §4.
**Companion to** [`reg_slave_architecture.md`](reg_slave_architecture.md) and
[`mem_slave_architecture.md`](mem_slave_architecture.md).

---

## 1. What it is for

One master port, two slave ports, an address decode and a response mux. It is
the smallest module in the project and it is the one that unblocks the most:
`DECERR`, three `cg_address_region` bins, F17 and F18, and the injection §9
numbers BUG-005.

It also changes what the environment *is*. Until it existed, each testbench top
held exactly one slave and every address the master issued was answered by that
slave — so `cg_address_region` recorded the address **issued** rather than the
traffic **routed**, and [`coverage_status.md`](coverage_status.md) said so at
length rather than reporting a green metric it could not defend. With a decode
in the design, that distinction collapses: the bins now mean what their names
say.

## 2. The three decisions

### 2.1 The decode is a range comparison, not a bit test

§4 puts an unmapped gap at `0x1400`–`0x1FFF`:

```
0x0000_0000 .. 0x0000_0FFF   register file    4 KB
0x0000_1000 .. 0x0000_13FF   memory           1 KB
0x0000_1400 .. 0xFFFF_FFFF   unmapped      -> DECERR
```

`ADDR[12]` alone routes `0x1400` to memory. So does `ADDR[13]`. Both are the
obvious implementation and both are wrong, and the gap exists in the
specification precisely so that they are — §7 says as much, and §9 makes
"decodes on `ADDR[13]` alone" the BUG-005 injection.

So the decode compares against limits. The register region's lower bound is
absent, because `REG_BASE` is 0 and the comparison would be vacuous — Verilator
says so (`UNSIGNED`). Deleting a vacuous term is how a decode silently breaks
when the region later moves, so the assumption is checked at time zero with a
`$fatal` rather than left implicit. **A comparison that cannot fail is the same
defect class as a cover point that cannot fail** ([BUG-007](bug_reports/BUG-007.md)).

### 2.2 W can arrive before AW, and then the destination is unknown

This is the part §7 calls out as hard, and it is why the write path is a state
machine rather than a mux.

§3 rule 4 makes AW/W ordering the master's choice. A slave can accept a W beat
before AW because it has only one place to put it. **An interconnect cannot** —
until AW arrives it does not know which slave the beat belongs to, and
forwarding it to a guess is unrecoverable.

The beat is therefore held. One entry is sufficient and provably so: §1 caps
outstanding writes at one, so a second W cannot be accepted until the first
write's B handshake completes.

```
   W_COLLECT ── both halves in hand ──> W_FWD ──> W_WAIT_B ──> W_RESP ──┐
       ^                    │                                          │
       │                    └── destination unmapped ──> W_RESP ────────┤
       └──────────────── master accepts B ────────────────────────────  ┘
```

`S_AWREADY` and `S_WREADY` are asserted independently in `W_COLLECT` and
together everywhere else. That gives §1's single-outstanding rule for free:
leaving the state drops both, and returning to it on the master's B handshake
raises them on the next cycle — which is exactly the shape `c_b2b_write` covers.

The bypass mux on `aw_addr_now` is not optional. On the cycle the *later* half
is accepted, its latch has not been written yet, so the decision to leave
`W_COLLECT` — and the destination that decision depends on — has to read the
bus. Omitting it is the same defect class as a register slave that uses stale
latch data on a same-cycle AW+W.

### 2.3 `DECERR` is produced here and nowhere else

§4 draws the line: `DECERR` means the transaction could not be routed at all;
`SLVERR` means a slave owns the address and rejected the access. Neither slave
contains a code path that can emit `2'b11` — both define only `RESP_OKAY` and
`RESP_SLVERR` — so an unmapped transaction is answered by this module and never
forwarded.

That claim is now **measured** rather than argued. On `sanity_sys_tb`, with the
checker bound to all three ports:

| Cover point | master port | slave ports |
|---|---|---|
| `c_resp_decerr` | **7** | **0** |

The left column is the first non-zero `DECERR` count in this project's history.
The right column is the specification's claim, verified.

## 3. Checked from both sides

`axi4lite_sys_bind.sv` binds the protocol checker to the interconnect's
master-facing port; `axi4lite_reg_bind.sv` and `axi4lite_mem_bind.sv` bind to
the slave **modules**, so they reach the instances the system top creates. A
system build therefore carries three checker instances:

| Instance | Sees the interconnect as |
|---|---|
| `u_ic.u_chk_m` | a **slave**, from the master's side |
| `u_reg.u_chk` | a **master**, from the register slave's side |
| `u_mem.u_chk` | a **master**, from the memory slave's side |

Every protocol rule the interconnect owes the master, and every rule it owes
each slave, is a bound assertion rather than a review comment. All three were
silent on the first run.

`CHECK_ALIGN` is 0 on the master-port instance and 1 on the two slave-side ones
— the only parameter difference anywhere in the project. Alignment is a
slave-side obligation: §4's precedence puts *unmapped* above *misaligned*, so a
misaligned unmapped address returns `DECERR`, and asserting an alignment rule at
the master port would state a requirement this module does not own.

## 4. One consequence worth stating before someone reports it as a hole

AW and W are forwarded **together**, so on a slave port they are always accepted
in the same cycle. `c_w_before_aw` on a slave-port checker instance therefore
stays at 0 permanently, and it should:

| Cover point | master port | slave ports |
|---|---|---|
| `c_w_before_aw` | **3** | **0** |

W-before-AW is a property of the master port. The interconnect absorbs the
ordering — that is what holding the beat *means*. A zero in the right-hand
column is the design working, not the stimulus failing, and it is written down
here so that it is never "closed" by adding stimulus that cannot reach it.

## 5. What it does not do

Scope boundaries, recorded so they are not mistaken for oversights.

| Not done | Why |
|---|---|
| Arbitration between masters | One master port. Multi-master needs ID tracking, which §1 puts out of scope. |
| Outstanding depth > 1 | §1 caps it at one read and one write. The held-W buffer is one entry *because of* that cap, and would need to be a queue without it. |
| Cross-slave read/write concurrency limits | The read and write state machines are independent, so a read to memory may run alongside a write to registers. Both slaves support one of each; nothing is shared. |
| Combinational response pass-through | §3's frozen timing decision requires registered responses. A `DECERR` therefore costs one cycle through `W_RESP` rather than being answered in the accept cycle. |
| Address decode for a third slave | Two ports is what the map has. Adding one is a `dest_e` value, a limit pair and a fan-out block. |
