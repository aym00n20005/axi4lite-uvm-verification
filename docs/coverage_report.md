# Coverage — measured

**GENERATED** by `scripts/coverage_report.py` at commit `c967aea`.
Do not edit — run `make coverage`. The *justifications* for anything
uncovered live in [coverage_status.md](coverage_status.md), which is written
by hand, because verification plan §5 requires a written reason and a
generator cannot supply one.

## Cover properties — SVA, local, Verilator

One table per bench, and within a bench one column per checker **instance**.
Not merged into a single column, because the difference between the instances
is the result rather than noise: `c_resp_decerr` is non-zero at the master
port and zero at both slave ports, which is spec §4's claim — the interconnect
produces DECERR and no slave can — measured rather than argued.

Instance paths are Verilator's own. A `u_*` prefix is its merge of two
instances that share a parameterisation, so on a system build the two
`CHECK_ALIGN=1` slave binds arrive as one column and the `CHECK_ALIGN=0`
master-port bind as another.

### `sanity_mem_tb`

| Cover point | `dut.u_chk` |
|---|---|
| `c_aw_before_w` | **1** |
| `c_aw_w_same_cycle` | **11** |
| `c_b2b_read` | 0 |
| `c_b2b_write` | 0 |
| `c_misaligned_ar` | **1** |
| `c_misaligned_aw` | **1** |
| `c_partial_strobe` | **6** |
| `c_read_backpressure` | 0 |
| `c_resp_decerr` | 0 |
| `c_resp_okay` | **24** |
| `c_resp_slverr` | **2** |
| `c_w_before_aw` | **1** |
| `c_write_backpressure` | 0 |
| `c_zero_strobe` | **1** |

### `sanity_rand_tb`

| Cover point | `u_*.u_chk` | `u_ic.u_chk_m` |
|---|---|---|
| `c_aw_before_w` | 0 | **121** |
| `c_aw_w_same_cycle` | **705** | **552** |
| `c_b2b_read` | 0 | **633** |
| `c_b2b_write` | 0 | **650** |
| `c_misaligned_ar` | **55** | **61** |
| `c_misaligned_aw` | **59** | **63** |
| `c_partial_strobe` | **320** | **363** |
| `c_read_backpressure` | 0 | **2475** |
| `c_resp_decerr` | 0 | **195** |
| `c_resp_okay` | **1053** | **1031** |
| `c_resp_slverr` | **334** | **333** |
| `c_w_before_aw` | 0 | **127** |
| `c_write_backpressure` | 0 | **2793** |
| `c_zero_strobe` | **18** | **23** |

### `sanity_sys_tb`

| Cover point | `u_*.u_chk` | `u_ic.u_chk_m` |
|---|---|---|
| `c_aw_before_w` | 0 | **1** |
| `c_aw_w_same_cycle` | **8** | **6** |
| `c_b2b_read` | 0 | 0 |
| `c_b2b_write` | 0 | 0 |
| `c_misaligned_ar` | **2** | **3** |
| `c_misaligned_aw` | 0 | 0 |
| `c_partial_strobe` | **2** | **2** |
| `c_read_backpressure` | 0 | 0 |
| `c_resp_decerr` | 0 | **7** |
| `c_resp_okay` | **22** | **22** |
| `c_resp_slverr` | **5** | **5** |
| `c_w_before_aw` | 0 | **3** |
| `c_write_backpressure` | 0 | 0 |
| `c_zero_strobe` | 0 | 0 |

### `sanity_tb`

| Cover point | `dut.u_chk` |
|---|---|
| `c_aw_before_w` | **1** |
| `c_aw_w_same_cycle` | **11** |
| `c_b2b_read` | 0 |
| `c_b2b_write` | 0 |
| `c_misaligned_ar` | **1** |
| `c_misaligned_aw` | **1** |
| `c_partial_strobe` | **2** |
| `c_read_backpressure` | 0 |
| `c_resp_decerr` | 0 |
| `c_resp_okay` | **26** |
| `c_resp_slverr` | **5** |
| `c_w_before_aw` | **1** |
| `c_write_backpressure` | 0 |
| `c_zero_strobe` | **1** |

**14 of 14 cover properties are non-zero somewhere.**

### Zero, and for how long

A count that has been zero across several runs is either a stimulus gap or a
structural fact. This table says *how long*; `coverage_status.md` says *which*.

| Cover point | Instance | Consecutive runs at zero |
|---|---|---|
| `c_aw_before_w` | `sanity_rand_tb.u_*.u_chk` | 3 |
| `c_aw_before_w` | `sanity_sys_tb.u_*.u_chk` | 3 |
| `c_b2b_read` | `sanity_mem_tb.dut.u_chk` | 3 |
| `c_b2b_read` | `sanity_rand_tb.u_*.u_chk` | 3 |
| `c_b2b_read` | `sanity_sys_tb.u_*.u_chk` | 3 |
| `c_b2b_read` | `sanity_sys_tb.u_ic.u_chk_m` | 3 |
| `c_b2b_read` | `sanity_tb.dut.u_chk` | 3 |
| `c_b2b_write` | `sanity_mem_tb.dut.u_chk` | 3 |
| `c_b2b_write` | `sanity_rand_tb.u_*.u_chk` | 3 |
| `c_b2b_write` | `sanity_sys_tb.u_*.u_chk` | 3 |
| `c_b2b_write` | `sanity_sys_tb.u_ic.u_chk_m` | 3 |
| `c_b2b_write` | `sanity_tb.dut.u_chk` | 3 |
| `c_misaligned_aw` | `sanity_sys_tb.u_*.u_chk` | 3 |
| `c_misaligned_aw` | `sanity_sys_tb.u_ic.u_chk_m` | 3 |
| `c_read_backpressure` | `sanity_mem_tb.dut.u_chk` | 3 |
| `c_read_backpressure` | `sanity_rand_tb.u_*.u_chk` | 3 |
| `c_read_backpressure` | `sanity_sys_tb.u_*.u_chk` | 3 |
| `c_read_backpressure` | `sanity_sys_tb.u_ic.u_chk_m` | 3 |
| `c_read_backpressure` | `sanity_tb.dut.u_chk` | 3 |
| `c_resp_decerr` | `sanity_mem_tb.dut.u_chk` | 3 |
| `c_resp_decerr` | `sanity_rand_tb.u_*.u_chk` | 3 |
| `c_resp_decerr` | `sanity_sys_tb.u_*.u_chk` | 3 |
| `c_resp_decerr` | `sanity_tb.dut.u_chk` | 3 |
| `c_w_before_aw` | `sanity_rand_tb.u_*.u_chk` | 3 |
| `c_w_before_aw` | `sanity_sys_tb.u_*.u_chk` | 3 |
| `c_write_backpressure` | `sanity_mem_tb.dut.u_chk` | 3 |
| `c_write_backpressure` | `sanity_rand_tb.u_*.u_chk` | 3 |
| `c_write_backpressure` | `sanity_sys_tb.u_*.u_chk` | 3 |
| `c_write_backpressure` | `sanity_sys_tb.u_ic.u_chk_m` | 3 |
| `c_write_backpressure` | `sanity_tb.dut.u_chk` | 3 |
| `c_zero_strobe` | `sanity_sys_tb.u_*.u_chk` | 3 |
| `c_zero_strobe` | `sanity_sys_tb.u_ic.u_chk_m` | 3 |

## Functional coverage — UVM, imported from EDA Playground

No UVM log has been imported yet.

```bash
make playground PLAY=sys      # paste, run on Xcelium, save the log
make import-log LOG=sim/logs/sys.log TEST=axi_regression_test
make coverage
```

## Trend

3 measurement(s) recorded in `results/coverage_history.json`.

| Commit | Date | Cover points non-zero |
|---|---|---|
| `d5ade6e` | 2026-09-06T23:07 | 52/84 |
| `7a357b6` | 2026-09-07T04:08 | 52/84 |
| `c967aea` | 2026-09-07T04:11 | 52/84 |

