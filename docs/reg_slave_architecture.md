# Register-File Slave — Architecture

**Day 3 · 14 Aug 2026 · precedes `rtl/axi4lite_reg_slave.sv`**

Design derived from `dut_spec.md` §5 and, where the prose is looser than the
checker, from the assertions in `tb/interface/axi4lite_if.sv`. Every block below
cites the clause it implements.

---

## 1. Block structure

```
                 ┌──────────────────────────────────────────────┐
   AWADDR ──────▶│ aw_captured / awaddr_q                       │
   AWVALID ─────▶│   (write address accept-flag + latch)        │──┐
   AWREADY ◀─────│                                              │  │
                 ├──────────────────────────────────────────────┤  │
   WDATA ───────▶│ w_captured / wdata_q / wstrb_q               │  ├─▶ do_write
   WSTRB ───────▶│   (write data accept-flag + latch)           │──┘   (combinational:
   WVALID ──────▶│                                              │       both halves held)
   WREADY ◀──────│                                              │
                 └──────────────────────┬───────────────────────┘
                                        │
                          ┌─────────────▼─────────────┐
                          │  decode + error precedence│  spec §4
                          │  misaligned > unimpl >    │
                          │  partial-strobe           │
                          └─────────────┬─────────────┘
                                        │
          ┌─────────────────────────────┼──────────────────────────┐
          │                             │                          │
  ┌───────▼────────┐           ┌────────▼────────┐        ┌────────▼────────┐
  │ register bank  │           │  INT_STATUS     │        │  bresp_q        │
  │ ctrl/config/   │           │  set-wins-clear │        │  bvalid_q       │──▶ B
  │ int_en/scratch │           │  event sources  │        └─────────────────┘
  └───────┬────────┘           └────────┬────────┘
          │                             │
  ┌───────▼────────┐                    │
  │ COUNTER (16b)  │────overflow────────┘
  │ reset_stats >  │
  │ increment      │
  └───────┬────────┘
          │
  ┌───────▼──────────────────────────────────────┐
  │ read-data mux + reserved-bit masking (§5)    │──▶ rdata_q / rresp_q / rvalid_q ──▶ R
  └──────────────────────────────────────────────┘
          ▲
  ARADDR ─┴─ ar_captured / araddr_q
```

Two **independent** accept-flags for AW and W, not a sequential FSM. Spec §3
rule 4 and §3's warning: *"Rule 4 is the one you will get wrong first."*

## 2. Write path

### 2.1 READY generation

```systemverilog
assign AWREADY = !aw_captured && !bvalid_q;
assign WREADY  = !w_captured  && !bvalid_q;
```

Two terms, each doing a distinct job:

- `!aw_captured` — we are not already holding an unmatched AW. Prevents a second
  address overwriting the first.
- `!bvalid_q` — a B response is outstanding. This is the term that satisfies
  `a_single_outstanding_write`.

The flags are independent, so an accepted W leaves `AWREADY` high and vice
versa. That is what makes W-before-AW work, and what makes `c_w_before_aw`
coverable.

### 2.2 The commit condition

```systemverilog
wire aw_hs = AWVALID && AWREADY;
wire w_hs  = WVALID  && WREADY;

wire do_write = (aw_captured || aw_hs) && (w_captured || w_hs) && !bvalid_q;
```

`do_write` is **combinational** and true on the cycle the *later* of the two
halves is accepted. Registering it into `bvalid_q` therefore places `BVALID`
exactly one cycle after that accept — which is what `a_bvalid_not_early` and
`a_b_not_stalled ##[0:8]` together demand, and what spec §3's frozen registered-
slave decision requires.

### 2.3 The bypass mux

On the commit cycle, one half may have been accepted cycles ago (latched) while
the other is being accepted *right now* (not yet latched). The payload used for
the write must select accordingly:

```systemverilog
wire [31:0] wr_addr = aw_captured ? awaddr_q : AWADDR;
wire [31:0] wr_data = w_captured  ? wdata_q  : WDATA;
wire [3:0]  wr_strb = w_captured  ? wstrb_q  : WSTRB;
```

Forgetting this mux is the classic bug: same-cycle AW+W writes stale latch
contents instead of the live bus.

### 2.4 Flag lifecycle

```systemverilog
if (do_write) begin
    aw_captured <= 1'b0;          // both halves consumed
    w_captured  <= 1'b0;
end else begin
    if (aw_hs) aw_captured <= 1'b1;
    if (w_hs)  w_captured  <= 1'b1;
end
```

Note what happens on the cycle *after* `do_write`: both flags are 0 again, so
`AWREADY` would go high on the `!aw_captured` term alone — but `bvalid_q` is now
1, and the `!bvalid_q` term holds READY low until the B handshake completes.
That second term is load-bearing; without it `a_single_outstanding_write` fires.

### 2.5 Back-to-back timing

`bvalid_q` clears the cycle after `BVALID && BREADY`, so the next AW can be
accepted one cycle after `b_done`. That is exactly the project's own definition
of back-to-back: `c_b2b_write : cover property (b_done ##1 aw_acc)`.

Zero-bubble would require `AWREADY` to depend combinationally on `BREADY` —
an input-to-output path across channels. Rejected: it buys one cycle and risks
a combinational loop with a master that gates `BREADY` on `AWREADY`.

## 3. Address decode — spec §4 / §5

Register region is 4 KB, so the offset is `addr[11:0]`.

```systemverilog
wire misaligned  = (addr[1:0] != 2'b00);
wire implemented = (addr[11:5] == 7'b0);    // offset < 0x20
wire [2:0] idx   =  addr[4:2];              // 8 registers
```

> **Spec §5 says "register selected by `ADDR[7:2]`". Taken literally that is a
> bug.** `ADDR[7:2]` only spans the low 256 bytes, so offset `0x100` aliases
> onto `CTRL` at `0x00` — while spec §4 requires everything in `0x20`–`0xFFF`
> to return SLVERR. The two clauses contradict. Resolution: the implemented
> check is on `addr[11:5] == 0`, and only the low three bits select the
> register. Spec §5 wording clarified to match.

This is the same *class* of defect as BUG-005 (interconnect decoding on
`ADDR[13]` alone): a decode that looks at too few bits and lets a plausible
address reach the wrong place.

## 4. Error precedence — spec §4

A strict priority cascade, so exactly one error is true and exactly one
`INT_STATUS` bit is set:

```systemverilog
wire err_misalign = misaligned;
wire err_unimpl   = !misaligned && !implemented;
wire err_strobe   = !misaligned &&  implemented && is_write && (wr_strb != 4'b1111);
```

| Priority | Condition | Response | INT_STATUS bit |
|---|---|---|---|
| 1 | unmapped address | DECERR | — (interconnect; slave never sees it) |
| 2 | misaligned | SLVERR | [1] |
| 3 | unimplemented offset | SLVERR | [0] |
| 4 | partial-strobe write | SLVERR | [2] |

`err_strobe` is write-only — reads carry no `WSTRB`. Per spec §5, `4'b0000`
counts as partial on the register slave (unlike memory, where it is a legal
no-op — spec §6).

**No error condition modifies register state.** The bank write is gated on
`do_write && !any_error`.

## 5. Register bank

| Offset | Name | Behaviour on write | Read value (reserved masked) |
|---|---|---|---|
| 0x00 | `CTRL` | `enable <= wdata[0]`, `reset_stats` pulse `<= wdata[1]` | `{30'b0, 1'b0, enable}` |
| 0x04 | `STATUS` | RO — discard, OKAY | `{30'b0, error, busy}` |
| 0x08 | `CONFIG` | `config_q <= wdata[7:0]` | `{24'b0, config_q}` |
| 0x0C | `INT_ENABLE` | `int_enable_q <= wdata[3:0]` | `{28'b0, int_enable_q}` |
| 0x10 | `INT_STATUS` | W1C per bit | `{28'b0, int_status_q}` |
| 0x14 | `SCRATCH` | `scratch_q <= wdata[31:0]` | `scratch_q` |
| 0x18 | `COUNTER` | RO — discard, OKAY | `{16'b0, counter_q}` |
| 0x1C | `ID` | RO — discard, OKAY | `32'hDEAD_BEEF` |

Reserved bits are masked **in the read mux**, not by masking the stored value —
either works, but masking on read keeps the stored width honest and makes F13
("reserved bits cannot retain written values") a single, obvious line of code.

Writes to RO registers are accepted with OKAY and discarded (spec §5).

### 5.1 `STATUS.busy`

```systemverilog
wire busy = aw_captured || w_captured || bvalid_q;
```

Write path only. Spec §5's rationale: if `busy` covered reads, reading `STATUS`
would itself be an in-flight read and the bit could never be observed as 0.

### 5.2 `INT_STATUS` — set beats clear

```systemverilog
for each bit n:
    if (event_n)                     int_status_q[n] <= 1'b1;   // set wins
    else if (w1c_write && wdata[n])  int_status_q[n] <= 1'b0;
```

The `if/else if` ordering *is* the spec §5 rule "set beats simultaneous clear —
the event must not be lost". Swapping the two branches is a real, plausible RTL
defect and a good directed test (F23).

Event sources: [0] unimplemented offset · [1] misaligned · [2] partial-strobe
write · [3] COUNTER overflow. Read and write paths can both raise an event in
the same cycle, so the event terms are OR-ed across both.

### 5.3 `COUNTER` — 16 bits

```systemverilog
if (reset_stats_pulse)  counter_q <= 16'h0;      // priority over increment
else if (ctrl_enable)   counter_q <= counter_q + 1;
```

Overflow event: `ctrl_enable && !reset_stats_pulse && (counter_q == 16'hFFFF)`
sets `INT_STATUS[3]`.

`reset_stats` does not disturb `enable` — they are separate bits of separate
registers-worth of state, independently testable (spec §5).

## 6. Read path

```systemverilog
assign ARREADY = !rvalid_q;
```

**No address latch is needed on the read side.** Because `ARREADY` is gated on
`!rvalid_q`, the response is computed and registered on the very cycle AR is
accepted, straight from `ARADDR` — which is stable that cycle by definition, as
it is being accepted. The `ar_captured` / `araddr_q` pair sketched in §1 turned
out to be dead weight and is not in the RTL. The write side genuinely needs its
latches, because AW and W can be separated by arbitrarily many cycles; the read
side has nothing to wait for.

AR accepted at cycle T → `rvalid_q`, `rdata_q`, `rresp_q` all registered at
T+1. One cycle, as the registered-slave decision requires. `ARREADY` drops while
`rvalid_q` is high, satisfying `a_single_outstanding_read`; it returns high one
cycle after `r_done`, making `c_b2b_read` coverable.

Reads are unaffected by writes and proceed concurrently — spec §1 allows one
write and one read in flight simultaneously.

**`RDATA` on an error response is driven to `32'h0`**, not left stale. AMBA
treats it as don't-care; a deterministic zero is chosen so the scoreboard can
check it rather than having to mask it.

## 7. Reset

`always_ff @(posedge ACLK or negedge ARESETn)` — asynchronous assert,
synchronous deassert, per spec §1's reset contract (the testbench only deasserts
on an active clock edge, so the DUT needs no reset synchroniser).

Every output register gets a reset value, so `a_no_x_valids` / `a_no_x_readys`
cannot fire. Reset values per spec §5: `CONFIG` = `0x0000_00FF`, everything else
0. `ID` is a constant, not a register.

## 8. Open decisions carried into RTL

All four are resolved and folded into `dut_spec.md` v0.3 — see its §10.

| # | Question | Resolution |
|---|---|---|
| D1 | Does a read of `STATUS` that completes OKAY clear `STATUS.error`? | No — a read of `STATUS` is transparent. Every other completed transaction updates the bit; a write wins a same-cycle tie. |
| D2 | Does `CTRL.reset_stats` ever read back as 1? | No — command bit, always reads 0. Internal one-cycle pulse clears `COUNTER`. |
| D3 | `ADDR[7:2]` decode wording | Decode on `ADDR[11:5] == 0` for implemented, `ADDR[4:2]` to select. §3 above. |
| D4 | `CHECK_ALIGN` for the memory slave | Set to 1 on both binds; spec §6 requires misaligned → SLVERR. |

A fifth, unlisted at the time: `RDATA` is `32'h0` on any error response, rather
than stale or don't-care, so the scoreboard can check it instead of masking it.
