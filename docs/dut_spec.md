# DUT Specification — AXI4-Lite Peripheral Subsystem

**Version 0.3 — 14 August 2026** · frozen at v0.2 on 12 August 2026; see §10 for what changed and why

This document is the **source of truth**. If the RTL does something not written here, either the RTL is wrong or this document is incomplete — and the second case is fixed by editing this file first, then the RTL. Never the other way round.

Every observable behaviour must be answerable by *"where is that defined in the spec?"*

Parameters: `ADDR_WIDTH = 32`, `DATA_WIDTH = 32`, `STRB_WIDTH = 4`.

---

## 1. Global constraints

| Constraint | Value |
|---|---|
| Protocol | AXI4-Lite, 32-bit address, 32-bit data |
| Outstanding writes | **1** |
| Outstanding reads | **1** |
| Concurrency | One write and one read may be in flight simultaneously |
| AW/W ordering | Independent — any order, including same cycle |
| Alignment | All accesses must be word-aligned (`ADDR[1:0] == 2'b00`) |
| Clock domains | Single, `ACLK` |
| Reset | `ARESETn`, active-low, asynchronous assert, synchronous deassert |

**Single-outstanding means:** once a write has had both AW and W accepted, the slave shall not accept a further AW or W until the B response handshake completes. Same for AR/R. This is a deliberate scope boundary — it keeps transaction IDs, reorder buffers and response queues out of the project.

**Reset contract:** the testbench shall only deassert `ARESETn` on an active `ACLK` edge. The DUT therefore contains no reset synchroniser and may use `always_ff @(posedge ACLK or negedge ARESETn)` directly.

---

## 2. AXI4-Lite signal list (slave side)

| Channel | Signal | Dir | Width |
|---|---|---|---|
| Global | `ACLK` | in | 1 |
| Global | `ARESETn` | in | 1 |
| AW | `AWADDR` / `AWPROT` / `AWVALID` | in | 32 / 3 / 1 |
| AW | `AWREADY` | out | 1 |
| W | `WDATA` / `WSTRB` / `WVALID` | in | 32 / 4 / 1 |
| W | `WREADY` | out | 1 |
| B | `BRESP` / `BVALID` | out | 2 / 1 |
| B | `BREADY` | in | 1 |
| AR | `ARADDR` / `ARPROT` / `ARVALID` | in | 32 / 3 / 1 |
| AR | `ARREADY` | out | 1 |
| R | `RDATA` / `RRESP` / `RVALID` | out | 32 / 2 / 1 |
| R | `RREADY` | in | 1 |

`AWPROT` and `ARPROT` are accepted and ignored.

Response encoding: `2'b00` OKAY, `2'b10` SLVERR, `2'b11` DECERR.

## 3. Protocol rules the slave must obey

1. Once a `VALID` is asserted it must not be deasserted until the corresponding `READY` has been sampled high.
2. `READY` may be asserted before, with, or after `VALID`. No reverse dependency.
3. Payload must remain stable while `VALID` is high and `READY` is low.
4. **AW and W are independent.** The slave must accept them in any order, including W-before-AW.
5. `BVALID` must not be asserted until both AW and W have been accepted. **It must not wait for `BREADY`.**
6. `RVALID` must not be asserted until AR has been accepted. **It must not wait for `RREADY`.**
7. All output `VALID` signals are low while `ARESETn` is low.

**Frozen timing decision:** this DUT is registered — `BVALID` and `RVALID` assert no earlier than the clock cycle *after* the accepts that enable them. The protocol permits same-cycle assertion for a combinational slave; we exclude it so the checker can use registered pending-flags. This is a tightening of the AMBA spec, deliberately chosen and recorded here so it is never mistaken for an accident.

**Rule 4 is the one you will get wrong first.** Use separate accept-flags for AW and W that combine to trigger the write.

---

## 4. Address map

| Range | Region | Response if accessed |
|---|---|---|
| `0x0000_0000` – `0x0000_0FFF` | Register file (4 KB) | per §5 |
| `0x0000_1000` – `0x0000_13FF` | Memory (1 KB) | per §6 |
| `0x0000_1400` – `0xFFFF_FFFF` | **Unmapped** | `DECERR` |

Unmapped transactions are terminated by the interconnect and **are not forwarded to any slave**.

Within the register region, offsets `0x20`–`0xFFF` are decoded but unimplemented → `SLVERR` from the register slave.

The distinction is worth being able to explain: **DECERR** means the interconnect couldn't route it at all; **SLVERR** means a slave owns the address but rejected the access.

### Error precedence

When more than one error condition applies to a single transaction, exactly one response is given and exactly one `INT_STATUS` bit is set, in this priority order:

1. **Unmapped address** → `DECERR` (interconnect; no `INT_STATUS` bit, since the slave never sees the transaction)
2. **Misaligned address** → `SLVERR`, sets `INT_STATUS[1]`
3. **Unimplemented register offset** → `SLVERR`, sets `INT_STATUS[0]`
4. **Partial-strobe register write** → `SLVERR`, sets `INT_STATUS[2]`

No error condition modifies any register or memory state.

On any error response, `RDATA` is driven to `0x0000_0000`. AMBA treats read data
as don't-care when `RRESP` is not `OKAY`; a deterministic zero is specified here
so the scoreboard can check it rather than mask it.

---

## 5. Register-file slave

Base `0x0000_0000`. Offset within the region is `ADDR[11:0]`.

- The offset is **implemented** if and only if `ADDR[11:5] == 0` — that is, an
  offset below `0x20`. Anything from `0x20` to `0xFFF` is unimplemented → `SLVERR`.
- Within the implemented range, the register is selected by `ADDR[4:2]`.

> **Changed in v0.3.** v0.2 said "register selected by `ADDR[7:2]`", which
> contradicts §4. `ADDR[7:2]` spans only the low 256 bytes, so offset `0x100`
> would alias onto `CTRL` at `0x00` and be serviced normally, where §4 requires
> `SLVERR`. The decode must qualify on the full offset.

| Offset | Name | Access | Reset | Implemented bits |
|---|---|---|---|---|
| 0x00 | `CTRL` | RW | 0x0000_0000 | [1:0] |
| 0x04 | `STATUS` | RO | 0x0000_0000 | [1:0] |
| 0x08 | `CONFIG` | RW | 0x0000_00FF | [7:0] |
| 0x0C | `INT_ENABLE` | RW | 0x0000_0000 | [3:0] |
| 0x10 | `INT_STATUS` | W1C | 0x0000_0000 | [3:0] |
| 0x14 | `SCRATCH` | RW | 0x0000_0000 | [31:0] |
| 0x18 | `COUNTER` | RO | 0x0000_0000 | **[15:0]** |
| 0x1C | `ID` | RO | 0xDEAD_BEEF | [31:0] |

### Reserved bits

**Reserved bits read as 0 and cannot store data.** After writing `0xFFFF_FFFF` to `CONFIG`, a read must return `0x0000_00FF` — not `0xFFFF_FFFF`. The same rule applies to `CTRL`, `INT_ENABLE` and `COUNTER`.

### `CTRL`

- `[0] enable` — RW. Gates `COUNTER` increment.
- `[1] reset_stats` — RW, **self-clearing**. **Always reads as 0.**
- Writing `reset_stats = 1` does **not** alter `enable`. The two bits are independently testable.

> **Clarified in v0.3.** v0.2 said "reads back as 0 on the cycle after the write
> completes", which leaves open whether a read landing on the write cycle itself
> could observe 1. It is specified as a command bit: the write produces a
> one-cycle internal pulse that clears `COUNTER`, and the read path returns 0 for
> `CTRL[1]` unconditionally. This is strictly stronger than the v0.2 wording, so
> it cannot violate it, and it removes a cycle-accurate race the scoreboard would
> otherwise have to model. The RAL model must declare `CTRL[1]` accordingly —
> it is not a plain RW bit and `bit_bash` will flag it if modelled as one.

### `STATUS` (read-only)

- `[0] busy` — 1 while the **write path** has an accepted transaction whose B response has not yet completed: AW accepted or W accepted, and B handshake not yet done.

  > **Why write-path only.** If `busy` also covered the read path, then reading `STATUS` would itself be an in-flight read, and `busy` would return 1 unconditionally — the bit could never be observed as 0. Restricting it to the write path means a read of `STATUS` concurrent with an in-flight write legitimately observes 1, and 0 otherwise. Testability drove this decision.

- `[1] error` — 1 when the most recently *completed* register transaction returned `SLVERR`. Cleared by reset, or by the next register transaction that completes with `OKAY`.

  **A read of `STATUS` itself is transparent: it does not update `error`.**
  Every other completed register transaction — read or write, to any other
  offset, or any erroring access — updates the bit.

  > **Clarified in v0.3.** Reading `STATUS` is itself a register transaction
  > completing with `OKAY`, so the v0.2 rule taken literally means the read that
  > observes `error == 1` also clears it, making the bit read-once. A status bit
  > destroyed by observing it is not a useful status bit. Excluding the
  > observation from the update rule resolves the contradiction rather than
  > hiding it. A misaligned access that *decodes* to the `STATUS` offset is not
  > a read of `STATUS` — it errors, and it sets the bit.
  >
  > If a write and a read complete on the same cycle, the **write** determines
  > the resulting value. Single-outstanding makes this reachable only with a
  > concurrent read and write, and a tiebreak must be specified rather than
  > left to synthesis.

### `INT_STATUS` — W1C, with real event sources

A write-1-to-clear register that nothing ever sets is untestable. These are the setting events:

| Bit | Set by |
|---|---|
| [0] | Access to an unimplemented register offset (0x20–0xFFF) |
| [1] | Misaligned register access |
| [2] | Partial-strobe register write attempted |
| [3] | `COUNTER` overflow (wrap from 0xFFFF to 0x0000) |

**W1C semantics:** bit *n* clears if and only if `WDATA[n] == 1`. Writing 0 leaves the bit unchanged.

Example — `INT_STATUS` is `4'b1011`, software writes `4'b0011` → result `4'b1000`. Bits 0 and 1 clear; bits 2 and 3 are untouched.

**Set-vs-clear collision:** if an event sets bit *n* on the same cycle a write would clear it, **set wins**. The event is real and must not be lost. This is a genuine RTL corner case and a good directed test.

### `COUNTER` — 16 bits

- Increments by 1 on each rising `ACLK` while `CTRL.enable == 1`.
- `CTRL.reset_stats` written as 1 clears `COUNTER` **with priority over increment**. If `enable` and `reset_stats` both apply on the same cycle, the result is 0.
- On wrap from `0xFFFF` to `0x0000`, sets `INT_STATUS[3]`.
- Bits [31:16] reserved, read 0.

  > **Why 16 bits and not 32.** A 32-bit counter overflows after ~4.3 billion cycles — roughly 43 seconds of simulated time at 10 ns. The overflow event would never fire in a regression, the `INT_STATUS[3]` path would be dead code, and its coverage bin would never close. 16 bits overflows in 65,536 cycles, which a single directed test reaches comfortably. Testability drove this too, and that reasoning belongs in the verification plan.

### WSTRB on register writes

- `WSTRB == 4'b1111` → normal write.
- `WSTRB != 4'b1111` → **`SLVERR`, register unchanged, `INT_STATUS[2]` set.** This includes `4'b0000`.

This gives a very clean check: partial-strobe write → SLVERR → register unchanged. Three things to verify in one transaction.

### Writes to RO registers

Accepted with `OKAY`, data discarded, no state change. Applies to `STATUS`, `COUNTER`, `ID`.

---

## 6. Memory slave

Base `0x0000_1000`, 1 KB = 256 words. Word selected by `ADDR[9:2]`.

- **`WSTRB` is honoured.** Byte *n* is written only when `WSTRB[n]` is 1.
- `WSTRB == 4'b0000` is a legal no-op write returning `OKAY`. Memory unchanged.
- Reads always return the full 32-bit word regardless of anything.
- Misaligned access → `SLVERR`, no state change. The memory slave has no `INT_STATUS`; the error is reported on the bus only.
- **Reset does not clear memory contents.** This matches real RAM and is stated explicitly so it isn't mistaken for a bug during scoreboard bring-up.
- All 256 words are implemented. There is no unimplemented-offset case inside the memory region, because everything above `0x13FF` is caught by the interconnect as `DECERR`.

---

## 7. Interconnect — September milestone, do not build in August

- One master port, two slave ports.
- Decode per §4. Note this is **not** a single-bit decode: `0x1400`–`0x1FFF` must produce `DECERR` even though it lies inside what a naive `ADDR[12]` decode would route to memory. That gap exists precisely so the decode is non-trivial and the DECERR path is reachable from a plausible-looking address.
- Unmapped → `DECERR` on `BRESP`/`RRESP`, transaction not forwarded to any slave.
- Response mux routes B and R back from the selected slave.
- The AW/W independence problem gets harder here: if W arrives before AW, the interconnect doesn't yet know which slave to route it to and must hold it.

---

## 8. Build order

1. `rtl/axi4lite_reg_slave.sv` — start here; it is where the interesting semantics live.
2. `rtl/axi4lite_mem_slave.sv` — mostly `WSTRB` masking.
3. `tb/sanity_tb.sv` — a crude non-UVM testbench that does one write, one read, and `$display`s the result. Its only job is proving the RTL breathes before UVM goes on top. Deleted later.

Do not write the interconnect, and do not start UVM, until a plain write and read work end to end.

---

## 9. Injected bugs — testbench qualification (November)

Kept on a `bug-injection` branch, one commit each, so any single bug can be checked out in isolation.

| ID | Where | Injection | Caught by |
|---|---|---|---|
| BUG-001 | **Driver** | Deassert `AWVALID` while `AWREADY` is still low, before the handshake completes | SVA `a_awvalid_stable` |
| BUG-002 | **DUT** | Register slave asserts `BVALID` after AW is accepted but before W is accepted | SVA `a_bvalid_not_early` |
| BUG-003 | DUT | Memory slave ignores `WSTRB`, always writes all four bytes | Scoreboard |
| BUG-004 | DUT | `INT_STATUS` implemented as plain RW | RAL access-policy test |
| BUG-005 | DUT | Interconnect decodes on `ADDR[13]` alone — `0x1400` wrongly reaches memory instead of returning DECERR | Scoreboard + decode test |
| BUG-006 | DUT | `COUNTER` not cleared by `CTRL.reset_stats` | Directed test |

**Note on BUG-001.** It is injected into the *driver*, not the DUT. `AWVALID` is master-driven, so no slave-side defect can violate `AWVALID` stability — v0.1 of this spec paired that bug with that assertion incorrectly. BUG-001 qualifies the checker; BUG-002 is the DUT-side defect that the same class of assertion catches. Both are kept deliberately: one proves the checker works, the other proves it catches a real design defect.

If the testbench misses any of these, the testbench is what's broken. Fix it before fixing the DUT.

---

## 10. Revision history

The spec is the source of truth, so every clarification that changes what the
RTL must do is a spec revision, made *before* the RTL is written.

### v0.3 — 14 August 2026

Four items, all found while deriving the register-slave architecture from v0.2.
Two were genuine contradictions; two were gaps that would have been silently
decided in RTL.

| # | Section | Change | Kind |
|---|---|---|---|
| 1 | §5 | Register decode is `ADDR[11:5] == 0` for implemented, `ADDR[4:2]` to select. Was "`ADDR[7:2]`", which aliased offset `0x100` onto `CTRL` and contradicted §4. | contradiction |
| 2 | §5 | `CTRL.reset_stats` always reads 0. Was "reads 0 on the cycle after the write completes", which left a cycle-accurate race undefined. | gap |
| 3 | §5 | A read of `STATUS` does not update `STATUS.error`; write wins a same-cycle tie. Was self-contradictory, since reading `STATUS` is itself an OKAY transaction that would clear the bit being read. | contradiction |
| 4 | §4 | `RDATA` is `0x0000_0000` on any error response. Was unspecified. | gap |

A fifth item is outside this document: `axi4lite_protocol_checker`'s
`CHECK_ALIGN` parameter comment recommended `0` for the memory slave, which
would disable a check §6 requires. Both slave binds use `CHECK_ALIGN = 1`.

**Verification status of these revisions**, updated 21 August 2026. A spec
decision that no test can distinguish from the alternative reading is not
really a decision, so each one is tracked to a discriminating test.

| # | Verified by | Status |
|---|---|---|
| 1 | `axi_smoke_seq`: write `0x100` returns SLVERR and `CTRL` is unaliased. Also `sanity_tb`. Under the v0.2 `ADDR[7:2]` decode this write lands on `CTRL` and returns OKAY. | ✅ 21 Aug, Xcelium |
| 2 | `axi_smoke_seq`: write `CTRL = 0x1`, read back `0x0000_0001`. `reset_stats` never reads 1. | ✅ 21 Aug, Xcelium |
| 3 | `axi_smoke_seq`: SLVERR, then read `STATUS` twice — the bit must survive the first read. Under the v0.2 wording the second read returns 0. | ✅ 21 Aug, Xcelium |
| 4 | `axi_smoke_seq` and `sanity_tb`: misaligned read returns `RDATA == 0`. | ✅ 21 Aug, Xcelium |

### v0.2 — 12 August 2026

Specification freeze.
