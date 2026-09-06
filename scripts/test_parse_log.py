#!/usr/bin/env python3
"""test_parse_log.py -- the log parser, tested against real output.

    python3 scripts/test_parse_log.py

Every other tool in scripts/ is built on parse_log's signatures:
triage.py clusters by them, run_regression.py records them,
coverage_report.py and vplan_trace.py trust its verdicts. A parser that
has only ever been pointed at passing logs is exactly the kind of
metric that cannot fail -- which is what BUG-007 was.

So the samples below are REAL output, copied from this project's own
logs and bug reports, one per simulator and one per failure class. Each
case asserts three things:

    the verdict (PASS / FAIL / INCOMPLETE),
    that the expected signature is produced,
    and -- where it matters -- that a signature that should NOT appear
    does not.

The last of those is the half that catches over-normalisation. Two
different defects collapsing into one signature is silent, and it is the
failure mode that would make triage.py confidently wrong.
"""

import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import parse_log


CASES = []


def case(name, text, status, expect=(), reject=(), checks=None):
    CASES.append(dict(name=name, text=text, status=status,
                      expect=list(expect), reject=list(reject), checks=checks))


# ---------------------------------------------------------------- UVM
case("xcelium: scoreboard mismatch",
     """
UVM_INFO @ 0: reporter [RNTST] Running test axi_random_test...
UVM_ERROR @ 1755 NS: uvm_test_top.env.sb [SB] RDATA mismatch on READ  REGION_MEM  addr=0x00001008 : got 0x00000000 expected 0xdeadbeef
UVM_ERROR @ 2015 NS: uvm_test_top.env.sb [SB] RDATA mismatch on READ  REGION_MEM  addr=0x0000100c : got 0x00000000 expected 0xcafef00d
--- UVM Report Summary ---
** Report counts by severity
UVM_INFO :  142
UVM_WARNING :    0
UVM_ERROR :    2
UVM_FATAL :    0
""",
     "FAIL",
     expect=["UVM:SB:RDATA mismatch on READ REGION_MEM addr=<H> : got <H> expected <H>"],
     )

# The two mismatches above differ only in address and data. They MUST
# collapse to one signature -- that is what makes "200 failures are 3
# bugs" work.
case("xcelium: two mismatches, one signature",
     """
UVM_ERROR @ 1755 NS: uvm_test_top.env.sb [SB] RDATA mismatch on READ addr=0x00001008 : got 0x1 expected 0x2
UVM_ERROR @ 9999 NS: uvm_test_top.env.sb [SB] RDATA mismatch on READ addr=0x000013fc : got 0x9 expected 0x8
--- UVM Report Summary ---
UVM_ERROR :    2
UVM_FATAL :    0
""",
     "FAIL",
     checks=lambda r: len(r["signatures"]) == 1)

# ...but a DIFFERENT message must not collapse into it.
case("xcelium: different messages stay separate",
     """
UVM_ERROR @ 1755 NS: uvm_test_top.env.sb [SB] RDATA mismatch on READ addr=0x00001008 : got 0x1 expected 0x2
UVM_ERROR @ 1760 NS: uvm_test_top.env.sb [SB] BRESP mismatch on WRITE addr=0x00001008 : got 0x0 expected 0x2
--- UVM Report Summary ---
UVM_ERROR :    2
UVM_FATAL :    0
""",
     "FAIL",
     checks=lambda r: len(r["signatures"]) == 2)

# ---------------------------------------------------------------- SVA
case("xcelium: assertion failure",
     """
*E,ASRTST (time 5 NS) Assertion tb_top.dut.u_chk.a_reset_valids_low has failed
--- UVM Report Summary ---
UVM_ERROR :    0
UVM_FATAL :    0
""",
     "FAIL",
     expect=["ASSERT:a_reset_valids_low"])

case("verilator: assertion failure (BUG-002's, verbatim)",
     """
[335000] %Error: axi4lite_if.sv:125: Assertion failed in sanity_tb.dut.u_chk.a_bvalid_not_early: BVALID asserted before both AW and W were accepted
- sanity_tb.sv:288: Verilog $finish
""",
     "FAIL",
     expect=["ASSERT:a_bvalid_not_early"],
     # The bench top must NOT be filed as an assertion.
     reject=["ASSERT:sanity_tb"])

# The same property failing on two slave instances is ONE defect.
case("verilator: same assertion, two instances, one signature",
     """
[100000] %Error: axi4lite_if.sv:125: Assertion failed in sanity_sys_tb.u_reg.u_chk.a_bvalid_not_early: x
[200000] %Error: axi4lite_if.sv:125: Assertion failed in sanity_sys_tb.u_mem.u_chk.a_bvalid_not_early: x
- $finish
""",
     "FAIL",
     checks=lambda r: r["signatures"] == ["ASSERT:a_bvalid_not_early"])

# ---------------------------------------------------------- bench checks
case("bench: FAIL lines whose names contain addresses",
     """
  FAIL   write 0x00001400 -> DECERR                   0x0         (expected 0x3       )
  FAIL   read  0x00001400 -> DECERR                   0x0         (expected 0x3       )
  FAIL     RDATA zeroed on error                      0xbaadbaad  (expected 0x0       )
 RESULT: 3 of 36 checks FAILED
[1905000] %Fatal: sanity_sys_tb.sv:334: Assertion failed in sanity_sys_tb: sanity_sys_tb failed
""",
     "FAIL",
     expect=["CHECK:write <H> -> DECERR",
             "CHECK:read <H> -> DECERR",
             "CHECK:RDATA zeroed on error",
             "FATAL:sanity_sys_tb failed"],
     # A $fatal is not an SVA failure.
     reject=["ASSERT:sanity_sys_tb"],
     checks=lambda r: r["checks"] == 36 and r["failed"] == 3)

case("bench: clean pass",
     """
  PASS   ID reads 0xDEADBEEF                          0xdeadbeef
========================================================================
 RESULT: all 31 checks passed
========================================================================
- sanity_tb.sv:288: Verilog $finish
""",
     "PASS",
     checks=lambda r: r["checks"] == 31 and r["passed"] == 31 and not r["signatures"])

# --------------------------------------------------------------- watchdog
case("watchdog: a stalled bus",
     """
=================== WATCHDOG ===================
 no bus activity for 20000 ns. ARESETn=1
   AW  VALID=1 READY=0  ADDR=0x00000014
================================================
%Fatal: watchdog: no bus activity for 20000 ns
""",
     "FAIL",
     # <T>, not "<N> ns". A duration is a time, and normalising it that
     # way is what makes a watchdog trip at 20 us and one at 50 us the
     # same signature -- which they are: one defect class, the bus
     # stopped. This expectation was written the other way round first
     # and the parser was right.
     expect=["WATCHDOG:no bus activity for <T>"])

# ------------------------------------------------------------ truncation
# The one that matters most. Playground kills an over-running job with
# exit 137 and no message, so the log simply STOPS. There is no error in
# it anywhere, and a parser that only looks for errors calls it a pass.
case("truncated: a killed job is not a pass",
     """
UVM_INFO @ 0: reporter [RNTST] Running test axi_regression_test...
UVM_INFO @ 120 NS: uvm_test_top [axi_regression_test] ================ F09  reset ================
UVM_INFO @ 340 NS: uvm_test_top.env.agent.mon [axi_monitor] observed 3 writes
""",
     "INCOMPLETE",
     expect=["INCOMPLETE:no completion marker"])

# ---------------------------------------------------------- elaboration
case("slang: BUG-010's own error",
     """
sim/playground_smoke.sv:174:34: error: invalid operands to binary expression ('bit' and 'void')
        soft (kind == AXI_WRITE) -> strb dist {
Build failed: 1 error, 2 warnings
""",
     "FAIL",
     expect=["ELAB:invalid operands to binary expression ('bit' and 'void')"])


def main():
    failures = 0
    for c in CASES:
        r = parse_log.parse(c["text"], name=c["name"])
        problems = []

        if r["status"] != c["status"]:
            problems.append(f"status {r['status']}, expected {c['status']}")
        for sig in c["expect"]:
            if sig not in r["signatures"]:
                problems.append(f"missing signature {sig!r}")
        for sig in c["reject"]:
            if sig in r["signatures"]:
                problems.append(f"unwanted signature {sig!r}")
        if c["checks"] and not c["checks"](r):
            problems.append("extra condition failed")

        if problems:
            failures += 1
            print(f"  FAIL  {c['name']}")
            for p in problems:
                print(f"          {p}")
            print(f"          got: {r['signatures']}")
        else:
            print(f"  ok    {c['name']}")

    print()
    if failures:
        print(f"test_parse_log: {failures} of {len(CASES)} cases FAILED")
        return 1
    print(f"test_parse_log: all {len(CASES)} cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
