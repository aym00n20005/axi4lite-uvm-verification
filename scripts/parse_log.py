#!/usr/bin/env python3
"""parse_log.py -- turn a simulation log into a verdict and a signature.

    python3 scripts/parse_log.py sim/logs/sys.log
    python3 scripts/parse_log.py --json results/.../run.log

docs/automation_plan.md T2.

THE FAILURE SIGNATURE IS THE POINT.

Counting UVM_ERRORs tells you a run failed. It does not tell you whether
two hundred failed runs are two hundred bugs or three. A signature is a
normalised string -- every address, cycle number, time stamp, seed and
instance index stripped out -- so that the SAME defect produces the SAME
string from every run that hits it, and clustering becomes a dict
lookup.

    SCOREBOARD:RDATA_mismatch
    ASSERT:a_bvalid_not_early
    WATCHDOG:bus_stalled

That normalisation is the whole idea, and it is what triage.py is built
on. Getting it wrong in either direction is a real failure mode: too
aggressive and two different bugs collapse into one cluster; too little
and the same bug appears once per seed.

FOUR SIMULATORS, ONE PARSER.

This project's logs come from Xcelium (UVM, via EDA Playground),
Verilator (the local assertion flow), Icarus (functional smoke) and slang
(elaboration). Their failure formats have nothing in common, so each has
its own patterns and they all produce the same signature vocabulary.
"""

import argparse
import json
import pathlib
import re
import sys

# ---------------------------------------------------------------- patterns

# Numbers, times, hex literals and instance indices are what make two
# reports of one defect look different. Each is replaced by a token
# rather than deleted, so a signature still says WHERE the variable part
# was -- "addr=<H>" and "count=<N>" do not collapse into each other.
NORMALISE = [
    (re.compile(r"0x[0-9a-fA-F]+"),                     "<H>"),
    (re.compile(r"\b[0-9a-fA-F]{8}\b"),                 "<H>"),
    (re.compile(r"\b\d+(\.\d+)?\s*(ns|us|ps|ms|NS|US|PS|MS)\b"), "<T>"),
    (re.compile(r"@\s*\d+"),                            "@<T>"),
    (re.compile(r"\[\s*\d+\s*\]"),                      "[<N>]"),
    (re.compile(r"\b\d+\b"),                            "<N>"),
    (re.compile(r"\s+"),                                " "),
]

PATTERNS = [
    # ---- UVM (Xcelium) ----
    # UVM_ERROR @ 1234 ns: uvm_test_top.env.sb [SB] RDATA mismatch on ...
    ("uvm", re.compile(
        r"UVM_(?P<sev>ERROR|FATAL)\s*[@:].*?\[(?P<id>[A-Za-z0-9_]+)\]\s*(?P<msg>.*)")),
    # ---- SVA, Xcelium ----
    # *E,ASRTST (time 5 NS) Assertion tb_top.dut.u_chk.a_bvalid_not_early has failed
    ("xcelium_assert", re.compile(
        r"\*E,ASRTST.*?Assertion\s+(?P<hier>[\w.$\[\]]+?)(?:\s+has failed|\s*$)")),
    # ---- SVA, Verilator ----
    # %Error: axi4lite_if.sv:125: Assertion failed in sanity_tb.dut.u_chk.a_bvalid_not_early:
    ("verilator_assert", re.compile(
        r"%Error[^\n]*?Assertion failed in\s+(?P<hier>[\w.$\[\]]+)")),
    # A testbench's own $fatal renders the same way but as %Fatal. It is
    # not an assertion failure and must not be filed as one -- otherwise
    # every failing bench reports a bogus ASSERT:<top> signature
    # alongside the real cause.
    ("verilator_fatal", re.compile(
        r"%Fatal[^\n]*?Assertion failed in\s+[\w.$\[\]]+:\s*(?P<msg>[^\n]+)")),
    # ---- watchdog ----
    ("watchdog", re.compile(r"watchdog:\s*(?P<msg>[^\n]+)")),
    # ---- non-UVM bench self-checks ----
    # Two formats in this project:
    #   FAIL   <name>   0x<got>   (expected 0x<exp>)      sanity_*_tb
    #   FAIL  <free-form message>                          sanity_rand_tb
    # One pattern takes the whole line and signature() strips the value
    # column if there is one. Two patterns would double-report every
    # line of the first kind, and a pattern anchored on the value column
    # would silently see NONE of the second kind -- which is how 75
    # distinct random-traffic failures collapsed into a single FATAL
    # signature the first time this was written.
    ("bench_fail", re.compile(r"^\s*FAIL\s+(?P<msg>\S.*?)\s*$", re.M)),
    # ---- fatals from $fatal in a plain bench ----
    ("sv_fatal", re.compile(r"\$fatal[^\n]*?:\s*(?P<msg>[^\n]+)")),
    # ---- elaboration ----
    ("elab", re.compile(r"^(?P<file>[\w./-]+):(?P<line>\d+):\d+:\s*error:\s*(?P<msg>.+)$", re.M)),
]

# Counts, which are a different question from signatures: a run can have
# zero errors and still be wrong (see: a test that issued nothing), and a
# run can have one error repeated four hundred times.
COUNTERS = {
    "uvm_error":   re.compile(r"UVM_ERROR\b"),
    "uvm_fatal":   re.compile(r"UVM_FATAL\b"),
    "uvm_warning": re.compile(r"UVM_WARNING\b"),
}

# A test that ran to completion says so. Its absence is itself a finding:
# EDA Playground kills an over-running job with exit 137 and no message,
# so a truncated log has no error in it at all.
COMPLETION = [
    re.compile(r"UVM Report Summary"),
    re.compile(r"\$finish"),
    re.compile(r"RESULT:\s*all \d+ checks passed"),
]

# What the run itself reports about its own checks.
CHECK_TALLY = [
    re.compile(r"RESULT:\s*all (?P<passed>\d+) checks passed"),
    re.compile(r"RESULT:\s*(?P<failed>\d+) of (?P<total>\d+) checks FAILED"),
    re.compile(r"(?P<name>\w+):\s*(?P<checks>\d+) checks,\s*(?P<errors>\d+) failures"),
]


def normalise(text):
    out = text.strip()
    for rx, token in NORMALISE:
        out = rx.sub(token, out)
    return out.strip()


# "  FAIL   name of the check   0xdeadbeef  (expected 0x0)"
#                                 ^^^^^^^^^^^^^^^^^^^^^^^^^^ this part
VALUE_COLUMN = re.compile(
    r"\s+0x[0-9a-fA-F]+\s*(?:\(expected\s+0x[0-9a-fA-F]+\s*\))?\s*$")


def strip_value_column(msg):
    """Drop the trailing got/expected columns, keeping the check's name.

    The name is the signature; the values are the instance. Keeping them
    would give one signature per failing address, which is the opposite
    of what a signature is for.
    """
    return VALUE_COLUMN.sub("", msg)


def signature(kind, match):
    """One failure -> one normalised string."""
    if kind == "uvm":
        return f"UVM:{match.group('id')}:{normalise(match.group('msg'))[:90]}"
    if kind in ("xcelium_assert", "verilator_assert"):
        # The assertion NAME is the whole signature. Its instance path is
        # deliberately dropped: the same property failing on two slaves is
        # one defect, and keeping the hierarchy would report it as two.
        leaf = match.group("hier").split(".")[-1]
        return f"ASSERT:{leaf}"
    if kind == "watchdog":
        return f"WATCHDOG:{normalise(match.group('msg'))[:60]}"
    if kind == "bench_fail":
        return f"CHECK:{normalise(strip_value_column(match.group('msg')))[:80]}"
    if kind in ("sv_fatal", "verilator_fatal"):
        return f"FATAL:{normalise(match.group('msg'))[:80]}"
    if kind == "elab":
        return f"ELAB:{normalise(match.group('msg'))[:80]}"
    return f"UNKNOWN:{kind}"


def parse(text, name=""):
    findings = []
    seen = set()

    for kind, rx in PATTERNS:
        for m in rx.finditer(text):
            # UVM_ERROR lines that are only the report SUMMARY's tally are
            # not failures; skip them or every run reports one extra.
            if kind == "uvm" and "Report counts by severity" in m.group(0):
                continue
            sig = signature(kind, m)
            line_no = text.count("\n", 0, m.start()) + 1
            key = (sig, line_no)
            if key in seen:
                continue
            seen.add(key)
            findings.append(dict(
                signature=sig,
                kind=kind,
                line=line_no,
                raw=" ".join(m.group(0).split())[:200],
            ))

    counts = {k: len(rx.findall(text)) for k, rx in COUNTERS.items()}

    # The UVM report summary's own tally, which is authoritative where a
    # regex over the body is not: UVM_ERROR appears in the summary block
    # too, and messages can contain the string.
    m = re.search(r"UVM_ERROR\s*:\s*(\d+)", text)
    if m:
        counts["uvm_error"] = int(m.group(1))
    m = re.search(r"UVM_FATAL\s*:\s*(\d+)", text)
    if m:
        counts["uvm_fatal"] = int(m.group(1))
    m = re.search(r"UVM_WARNING\s*:\s*(\d+)", text)
    if m:
        counts["uvm_warning"] = int(m.group(1))

    completed = any(rx.search(text) for rx in COMPLETION)

    checks = passed = failed = 0
    for m in re.finditer(r"RESULT:\s*all (\d+) checks passed", text):
        checks += int(m.group(1)); passed += int(m.group(1))
    for m in re.finditer(r"RESULT:\s*(\d+) of (\d+) checks FAILED", text):
        failed += int(m.group(1)); checks += int(m.group(2))
        passed += int(m.group(2)) - int(m.group(1))
    for m in re.finditer(r"TOTAL\s+(\d+) checks\s+(\d+) failures", text):
        checks += int(m.group(1)); failed += int(m.group(2))
        passed += int(m.group(1)) - int(m.group(2))

    # A run with no failure signature and no completion marker is not a
    # pass. It is a truncated log, and calling it a pass is how a killed
    # job becomes a green regression.
    if findings or counts["uvm_error"] or counts["uvm_fatal"]:
        status = "FAIL"
    elif not completed:
        status = "INCOMPLETE"
    else:
        status = "PASS"

    if status == "INCOMPLETE" and not findings:
        findings.append(dict(
            signature="INCOMPLETE:no completion marker",
            kind="truncated", line=text.count("\n") + 1,
            raw="log ends without a UVM report summary, $finish or a RESULT line",
        ))

    return dict(
        name=name,
        status=status,
        completed=completed,
        counts=counts,
        checks=checks, passed=passed, failed=failed,
        signatures=sorted({f["signature"] for f in findings}),
        findings=findings,
    )


def parse_file(path):
    p = pathlib.Path(path)
    return parse(p.read_text(errors="replace"), name=p.name)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    results = [parse_file(p) for p in args.logs]

    if args.json:
        print(json.dumps(results if len(results) > 1 else results[0], indent=2))
        return 0

    worst = 0
    for r in results:
        mark = {"PASS": "ok  ", "FAIL": "FAIL", "INCOMPLETE": "????"}[r["status"]]
        print(f"  {mark} {r['name']:<28} "
              f"{r['passed']}/{r['checks']} checks, "
              f"{r['counts']['uvm_error']} UVM_ERROR, "
              f"{r['counts']['uvm_fatal']} UVM_FATAL")
        for s in r["signatures"]:
            print(f"         {s}")
        if r["status"] != "PASS":
            worst = 1
    return worst


if __name__ == "__main__":
    sys.exit(main())
