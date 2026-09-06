# Traceability — feature → test → result

**GENERATED** by `scripts/vplan_trace.py`. Do not edit — run `make vplan`.

Features from [verification_plan.md §3](verification_plan.md); claims from
`scripts/testlist.yaml`; results from regression `20260907_034533`.

The rows that matter are the ones that are **not** green. A matrix built from
the tests that exist is green by construction; this one is built from the
specification's feature list, so a feature nothing claims appears as
`UNCOVERED` with an empty test column.

| Status | Features |
|---|---|
| ✅ PASSING | **27** of 29 |
| ⏳ NOT RUN | **2** of 29 |

## Matrix

| | Feature | Planned method | Claimed by | Result |
|---|---|---|---|---|
| **F01** | Write path | Directed + random | `sanity_tb`, `sanity_mem_tb`, `sanity_rand_tb`, `axi_regression_test`, `axi_multiseed_test` | ✅ PASSING |
| **F02** | Read path | Directed + random | `sanity_tb`, `sanity_mem_tb`, `sanity_rand_tb`, `axi_regression_test`, `axi_multiseed_test` | ✅ PASSING |
| **F03** | AW/W independence | Constrained random | `sanity_sys_tb`, `sanity_rand_tb`, `axi_regression_test`, `axi_multiseed_test` | ✅ PASSING |
| **F04** | VALID stability | SVA | `sanity_tb`, `sanity_mem_tb`, `sanity_rand_tb` | ✅ PASSING |
| **F05** | Payload stability | SVA | `sanity_tb`, `sanity_mem_tb`, `sanity_rand_tb` | ✅ PASSING |
| **F06** | Response ordering | SVA | `sanity_tb`, `sanity_mem_tb`, `sanity_rand_tb` | ✅ PASSING |
| **F07** | No response stalling | SVA | `sanity_tb`, `sanity_mem_tb`, `sanity_rand_tb` | ✅ PASSING |
| **F08** | Single outstanding | SVA | `sanity_tb`, `sanity_rand_tb`, `axi_regression_test` | ✅ PASSING |
| **F09** | Reset behaviour | Directed | `sanity_tb`, `axi_regression_test` | ✅ PASSING |
| **F10** | Register RW access | RAL | `sanity_tb`, `axi_ral_test` | ✅ PASSING |
| **F11** | Register RO access | RAL | `sanity_tb`, `axi_ral_test` | ✅ PASSING |
| **F12** | Register W1C access | RAL | `sanity_tb`, `axi_ral_test` | ✅ PASSING |
| **F13** | Reserved fields | Directed | `sanity_tb`, `axi_ral_test` | ✅ PASSING |
| **F14** | Memory word access | Random | `sanity_mem_tb`, `sanity_rand_tb`, `axi_regression_test`, `axi_multiseed_test` | ✅ PASSING |
| **F15** | Byte enables | Constrained random | `sanity_mem_tb`, `sanity_sys_tb`, `sanity_rand_tb`, `axi_regression_test` | ✅ PASSING |
| **F16** | Register strobe rule | Directed | `sanity_tb`, `sanity_sys_tb`, `axi_regression_test` | ✅ PASSING |
| **F17** | Address decode | Directed + random | `sanity_sys_tb`, `sanity_rand_tb`, `axi_regression_test` | ✅ PASSING |
| **F18** | Unmapped access | Directed | `sanity_sys_tb`, `sanity_rand_tb`, `axi_regression_test` | ✅ PASSING |
| **F19** | Unimplemented offset | Directed | `sanity_tb`, `sanity_sys_tb`, `axi_regression_test` | ✅ PASSING |
| **F20** | Alignment | Directed + random | `sanity_tb`, `sanity_mem_tb`, `sanity_sys_tb`, `sanity_rand_tb`, `axi_regression_test` | ✅ PASSING |
| **F21** | Error precedence | Directed | `sanity_tb`, `sanity_sys_tb`, `sanity_rand_tb`, `axi_regression_test` | ✅ PASSING |
| **F22** | INT_STATUS events | Directed | `sanity_tb`, `axi_regression_test` | ✅ PASSING |
| **F23** | Set-vs-clear collision | Directed | `sanity_tb`, `axi_regression_test` | ✅ PASSING |
| **F24** | STATUS.busy | Directed | `axi_regression_test` | ⏳ NOT RUN |
| **F25** | STATUS.error | Directed | `sanity_tb`, `axi_regression_test` | ✅ PASSING |
| **F26** | COUNTER behaviour | Directed | `sanity_tb`, `axi_regression_test` | ✅ PASSING |
| **F27** | COUNTER overflow event | Directed | `axi_regression_test` | ⏳ NOT RUN |
| **F28** | Backpressure | Constrained random | `sanity_rand_tb`, `axi_regression_test`, `axi_multiseed_test` | ✅ PASSING |
| **F29** | Back-to-back | Directed | `sanity_rand_tb`, `axi_regression_test`, `axi_multiseed_test` | ✅ PASSING |

## Everything not passing

### F24 — STATUS.busy · ⏳ NOT RUN

Reads 1 during in-flight write, 0 otherwise

- **Planned method:** Directed (secondary: —)
- **Claimed by:** `axi_regression_test`
- **Why:** only claimed by tests that have not been run

### F27 — COUNTER overflow event · ⏳ NOT RUN

Wrap sets INT_STATUS[3]

- **Planned method:** Directed (secondary: —)
- **Claimed by:** `axi_regression_test`
- **Why:** only claimed by tests that have not been run

## Tests

| Test | Result | Features | What it is for |
|---|---|---|---|
| `sanity_tb` | PASS | F01, F02, F04, F05, F06, F07, F08, F09, F10, F11, F12, F13, F16, F19, F20, F21, F22, F23, F25, F26 | Register slave, directed. Every register semantic the spec states. |
| `sanity_mem_tb` | PASS | F01, F02, F04, F05, F06, F07, F14, F15, F20 | Memory slave, directed. WSTRB masking and the no-clear-on-reset rule. |
| `sanity_sys_tb` | PASS | F03, F15, F16, F17, F18, F19, F20, F21 | Interconnect + both slaves. The only local bench that can reach DECERR. |
| `sanity_rand_tb` | PASS | F01, F02, F03, F04, F05, F06, F07, F08, F14, F15, F17, F18, F20, F21, F28, F29 | Seeded constrained-random, ten seeds. Owns the four cover points no directed bench can reach -- c_b2b_write, c_b2b_read and both backpressure covers -- because it keeps the next transaction's VALID asserted while the current one is still completing. |
| `axi_regression_test` | MISSING | F01, F02, F03, F08, F09, F14, F15, F16, F17, F18, F19, F20, F21, F22, F23, F24, F25, F26, F27, F28, F29 | All fifteen directed sequences in one simulation, against the interconnect and both slaves, with the spec-derived scoreboard and the functional coverage model live. |
| `axi_ral_test` | MISSING | F10, F11, F12, F13 | uvm_reg_hw_reset_seq + uvm_reg_bit_bash_seq against the generated RAL model, plus explicit access-policy checks. bit_bash is what catches BUG-004. |
| `axi_multiseed_test` | MISSING | F01, F02, F03, F14, F28, F29 | Eight seeds of constrained-random traffic in one simulation. |

