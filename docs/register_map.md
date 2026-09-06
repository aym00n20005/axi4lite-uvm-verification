# Register map

**GENERATED** by `scripts/regmap_gen.py` from `scripts/regmap.yaml`.
Do not edit — edit the YAML and run `make regmap`.

The same YAML generates `rtl/gen/axi4lite_reg_pkg.sv` (the RTL's indices,
widths, resets and masks) and `tb/ral/axi_reg_block.sv` (the UVM RAL model), so
this table cannot disagree with either. `make regcheck` additionally verifies it
against §5 of [the specification](dut_spec.md), which remains the source of
truth: if the two disagree, the spec wins and this file is wrong.

Region base `0x00000000`, size `0x1000`.
A register is **implemented** iff `ADDR[11:5] == 0`; the register is selected by
`ADDR[4:2]`. Offsets `0x20`–`0xFFF` are decoded and unimplemented → `SLVERR`.

## Registers

| Offset | Name | Access | Reset | Implemented | Reserved |
|---|---|---|---|---|---|
| `0x00` | `CTRL` | RW | `0x00000000` | `0x00000003` | `0xFFFFFFFC` |
| `0x04` | `STATUS` | RO | `0x00000000` | `0x00000003` | `0xFFFFFFFC` |
| `0x08` | `CONFIG` | RW | `0x000000FF` | `0x000000FF` | `0xFFFFFF00` |
| `0x0C` | `INT_ENABLE` | RW | `0x00000000` | `0x0000000F` | `0xFFFFFFF0` |
| `0x10` | `INT_STATUS` | W1C | `0x00000000` | `0x0000000F` | `0xFFFFFFF0` |
| `0x14` | `SCRATCH` | RW | `0x00000000` | `0xFFFFFFFF` | `0x00000000` |
| `0x18` | `COUNTER` | RO | `0x00000000` | `0x0000FFFF` | `0xFFFF0000` |
| `0x1C` | `ID` | RO | `0xDEADBEEF` | `0xFFFFFFFF` | `0x00000000` |

Reserved bits read 0 and cannot retain written data — feature F13. The RTL
enforces this by storing each register at implemented width only, so a reserved
bit has no flop behind it.

## Fields

### `CTRL` — `0x00`, RW

Control. enable gates COUNTER; reset_stats is a command bit.

| Bits | Field | Access | Reset | Checked by RAL | Notes |
|---|---|---|---|---|---|
| `[0]` | `enable` | RW | `0x0` | yes | Gates COUNTER increment. |
| `[1]` | `reset_stats` | WC | `0x0` | yes | Self-clearing command bit. Writing 1 clears COUNTER with priority over increment; the bit itself always reads 0. Spec section 5, clarified in v0.3 -- modelled WC and not RW precisely so bit_bash expects the read-back of 0 rather than flagging it. |

### `STATUS` — `0x04`, RO

Status. Read-only, hardware-updated.

| Bits | Field | Access | Reset | Checked by RAL | Notes |
|---|---|---|---|---|---|
| `[0]` | `busy` | RO | `0x0` | **no** (volatile) | 1 while the write path has an accepted transaction whose B response has not completed. Cycle-level state; the scoreboard masks it for the same reason (axi_scoreboard.sv, mask 32'hFFFF_FFFE). |
| `[1]` | `error` | RO | `0x0` | **no** (volatile) | Last completed register transaction returned SLVERR. Hardware writes it on every completed transaction except a read of STATUS itself, which the RAL has no way to express -- so the RAL declines to check it and the scoreboard, which can express it, does. |

### `CONFIG` — `0x08`, RW

Configuration. Reserved bits [31:8] read 0 and cannot store data.

| Bits | Field | Access | Reset | Checked by RAL | Notes |
|---|---|---|---|---|---|
| `[7:0]` | `cfg` | RW | `0xFF` | yes | Reset value 0x0000_00FF -- the only non-zero reset in the block bar ID. |

### `INT_ENABLE` — `0x0C`, RW

Interrupt enables, one per INT_STATUS bit.

| Bits | Field | Access | Reset | Checked by RAL | Notes |
|---|---|---|---|---|---|
| `[3:0]` | `en` | RW | `0x0` | yes | Enable mask. Bit n pairs with INT_STATUS bit n. |

### `INT_STATUS` — `0x10`, W1C

Write-1-to-clear, with real hardware event sources. Set beats a simultaneous clear (spec section 5) -- that rule is behaviour and lives in the RTL, not here.

| Bits | Field | Access | Reset | Checked by RAL | Notes |
|---|---|---|---|---|---|
| `[0]` | `unimpl` | W1C | `0x0` | yes (volatile) | Set by an access to an unimplemented register offset (0x20-0xFFF). |
| `[1]` | `misalign` | W1C | `0x0` | yes (volatile) | Set by a misaligned register access. |
| `[2]` | `strobe` | W1C | `0x0` | yes (volatile) | Set by an attempted partial-strobe register write. |
| `[3]` | `overflow` | W1C | `0x0` | **no** (volatile) | Set by COUNTER wrapping 0xFFFF -> 0x0000. Inherits COUNTER's unpredictability, so it is masked here exactly as the scoreboard masks it (mask 32'hFFFF_FFF7). |

### `SCRATCH` — `0x14`, RW

Full-width RW with no side effects. The one register that is only storage.

| Bits | Field | Access | Reset | Checked by RAL | Notes |
|---|---|---|---|---|---|
| `[31:0]` | `value` | RW | `0x0` | yes | 32 bits, no reserved field, no hardware writer. |

### `COUNTER` — `0x18`, RO

Free-running 16-bit counter. 16 and not 32 so the overflow event is reachable in a regression -- a 32-bit counter would take ~43 s of simulated time and INT_STATUS[3] would be dead code (spec section 5).

| Bits | Field | Access | Reset | Checked by RAL | Notes |
|---|---|---|---|---|---|
| `[15:0]` | `count` | RO | `0x0` | **no** (volatile) | Increments every clock while CTRL.enable. A transaction-level model cannot know the value, so neither the RAL nor the scoreboard checks it -- except in the one state the scoreboard can prove (cleared by reset_stats and frozen with enable low), which is what catches BUG-006. |

### `ID` — `0x1C`, RO

Constant identifier. The one register whose read value is known before the DUT is built.

| Bits | Field | Access | Reset | Checked by RAL | Notes |
|---|---|---|---|---|---|
| `[31:0]` | `id` | RO | `0xDEADBEEF` | yes | Reads 0xDEAD_BEEF. Writes are accepted with OKAY and discarded. |

## Access types

Four are supported. `scripts/regmap_gen.py` rejects anything else rather than
guessing — adding a fifth means deciding what the RTL, the RAL and this document
each do with it, which is three decisions rather than one.

| Type | Meaning |
|---|---|
| `RW` | read-write |
| `RO` | read-only, writes accepted and discarded |
| `W1C` | write-1-to-clear |
| `WC` | write clears; the bit always reads 0 |

## Fields the RAL does not check

Four fields are hardware-writable, so the RAL mirror can legitimately disagree
with the DUT and a comparison would produce a false failure rather than a
detection. Each is masked in the RAL exactly where `tb/env/axi_scoreboard.sv`
masks it, so the two independent models make the same claim about what is
knowable from transactions alone.

- **`STATUS.busy`** — 1 while the write path has an accepted transaction whose B response has not completed. Cycle-level state; the scoreboard masks it for the same reason (axi_scoreboard.sv, mask 32'hFFFF_FFFE).
- **`STATUS.error`** — Last completed register transaction returned SLVERR. Hardware writes it on every completed transaction except a read of STATUS itself, which the RAL has no way to express -- so the RAL declines to check it and the scoreboard, which can express it, does.
- **`INT_STATUS.overflow`** — Set by COUNTER wrapping 0xFFFF -> 0x0000. Inherits COUNTER's unpredictability, so it is masked here exactly as the scoreboard masks it (mask 32'hFFFF_FFF7).
- **`COUNTER.count`** — Increments every clock while CTRL.enable. A transaction-level model cannot know the value, so neither the RAL nor the scoreboard checks it -- except in the one state the scoreboard can prove (cleared by reset_stats and frozen with enable low), which is what catches BUG-006.

Every other field is compared, including all of `INT_STATUS[2:0]` — that
comparison is what catches an `INT_STATUS` implemented as plain RW, which is the
injection specification §9 assigns to the RAL access-policy test.
