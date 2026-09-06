#!/usr/bin/env python3
"""llm_triage.py -- an advisory root-cause hypothesis, and its hit rate.

    python3 scripts/llm_triage.py --measure          # score it, and publish that
    python3 scripts/triage.py --llm                  # use it on a live regression

docs/automation_plan.md A1, and §3 of that document is the whole brief:

    "Every student at DVCon 2026 will say 'I used AI.' The program itself
    has a counter-theme asking who verifies the AI-written verifier.
    Claiming without measuring is how you lose the conversation."

    "Don't ship the AI layer without the measurement. Unmeasured, it's
    the weakest thing in your repo. Measured, it's among the strongest."

So the deliverable here is not the annotation. It is the NUMBER: fed a
failure signature and its log context and nothing else, how often does a
model name the actual root cause of a defect whose root cause is already
written down?

THE MEASUREMENT IS FAIR OR IT IS WORTHLESS.

Six injected bugs, each with a known root cause recorded in
docs/bug_reports/ before this script existed. The model is given the
failure signature and log excerpt ONLY -- never the bug report, never
the file it was injected into, never the fact that a bug was injected at
all. Scoring is by keyword against the recorded root cause, mechanically,
so the score does not depend on who is reading the answer.

Whatever comes out goes in the README. A measured 3 of 6 is a better
conversation than an unmeasured claim, because it means the limits were
looked at.

THREE BACKENDS:

    claude-cli   shells out to the installed `claude`. The default here,
                 because no API key is set on this machine.
    anthropic    ANTHROPIC_API_KEY, for CI.
    replay       reads results/llm_cache/. Committed, so the published
                 hit rate is REPRODUCIBLE by anyone who clones the repo
                 rather than being a number they have to take on trust.

replay is the one that matters. A measurement nobody else can rerun is
an anecdote.
"""

import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = ROOT / "results" / "llm_cache"

PROMPT = """You are triaging a failure from a SystemVerilog/UVM verification \
regression on an AXI4-Lite peripheral subsystem: a register-file slave with \
RW/RO/W1C registers, a byte-addressable memory slave, and an address-decoding \
interconnect that returns DECERR for unmapped addresses.

Failure signature:
{signature}

Log excerpt:
{context}

In at most 4 short lines, give:
ROOT CAUSE: your single best hypothesis for the underlying defect.
NEXT STEP: the one thing to look at first.

Be specific and concrete. Do not hedge across several possibilities."""


#---------------------------------------------------------------- backends

def _cache_key(signature, context):
    return hashlib.sha256(
        (signature + "\n" + context).encode("utf-8")).hexdigest()[:24]


def _cache_get(key):
    f = CACHE / f"{key}.json"
    if f.exists():
        return json.loads(f.read_text())["response"]
    return None


def _cache_put(key, signature, response):
    CACHE.mkdir(parents=True, exist_ok=True)
    (CACHE / f"{key}.json").write_text(json.dumps(
        dict(signature=signature, response=response), indent=2))


def _via_claude_cli(prompt):
    """The `claude` CLI, using whatever auth it already has.

    Chosen as the default because this machine has no ANTHROPIC_API_KEY
    and asking for one to run a measurement is a worse trade than using
    the tool that is already signed in.

    SEALED, AND THE SEAL IS THE MEASUREMENT.

    The first run of this harness scored 5/6 and the score was worthless.
    The CLI was invoked in the project directory, so it read the source:
    its BUG-005 answer cited "rtl/axi4lite_interconnect.sv:152" and its
    BUG-004 answer opened with "Checked the RTL and RAL in the repo". A
    model that can read the defect is not triaging, it is looking up the
    answer -- and the number it produces is a measurement of file access,
    not of root-cause inference.

    A triage tool in a real flow gets a signature and a log excerpt.
    Nothing else. So:

        cwd        an empty scratch directory, not the repository
        --disallowedTools   every file, search and execution tool
        --permission-mode   plan, which cannot act even if one were left

    Belt and braces on purpose: any one of these leaking would silently
    inflate the score, and an inflated score published as a measurement
    is worse than no measurement at all -- it is the exact failure
    automation_plan.md section 3 warns about, dressed up as rigour.
    """
    import tempfile
    sealed = [
        "claude", "-p",
        "--permission-mode", "plan",
        # ONE comma-separated argument. --disallowedTools is variadic, so
        # passing the names as separate words makes it swallow the prompt
        # that follows and every request fails with "Permission deny rule
        # 'You' matches no known tool". The prompt therefore goes on
        # STDIN, where nothing can consume it by accident.
        "--disallowedTools",
        "Read,Edit,Write,Bash,Glob,Grep,NotebookEdit,WebFetch,WebSearch,Task,Agent",
    ]
    with tempfile.TemporaryDirectory(prefix="llm_triage_sealed_") as empty:
        p = subprocess.run(sealed, input=prompt, capture_output=True,
                           text=True, timeout=300, cwd=empty)
    if p.returncode != 0:
        raise RuntimeError(f"claude CLI failed: {p.stderr[:300]}")
    out = p.stdout.strip()
    if not out:
        raise RuntimeError("claude CLI returned nothing")
    return out


def _via_anthropic(prompt):
    try:
        import anthropic
    except ImportError:
        raise RuntimeError("pip install anthropic, or use --backend claude-cli")
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise RuntimeError("ANTHROPIC_API_KEY not set")
    client = anthropic.Anthropic(api_key=key)
    msg = client.messages.create(
        model="claude-sonnet-5", max_tokens=400,
        messages=[{"role": "user", "content": prompt}])
    return "".join(b.text for b in msg.content if b.type == "text").strip()


BACKENDS = {"claude-cli": _via_claude_cli, "anthropic": _via_anthropic}


def hypothesise(signature, context, backend="replay", refresh=False):
    """One signature -> one advisory note. Cached, so a report can be
    regenerated without re-asking and without a different answer."""
    key = _cache_key(signature, context)
    if not refresh:
        hit = _cache_get(key)
        if hit is not None:
            return hit

    if backend == "replay":
        return "(no cached response; run with --backend claude-cli to generate one)"

    prompt = PROMPT.format(signature=signature, context=context[:1500])
    try:
        response = BACKENDS[backend](prompt)
    except Exception as e:                      # noqa: BLE001 -- advisory layer
        return f"(LLM unavailable: {e})"
    _cache_put(key, signature, response)
    return response


#------------------------------------------------------------- measurement
#
# Six injected bugs. Each entry carries ONLY what the tool would see in a
# real regression -- a signature and a log excerpt -- plus the recorded
# root cause and the keywords that decide the score. Nothing in `prompt`
# names the file, the bug, or the fact that anything was injected.
#
# Excerpts are the real ones, from docs/bug_reports/ and from this
# project's own logs.

BUGS = [
    dict(
        id="BUG-001",
        signature="ASSERT:a_awvalid_stable",
        context=(
            "%Error: axi4lite_if.sv:182: Assertion failed in "
            "tb_top.dut.u_chk.a_awvalid_stable: AWVALID deasserted before AWREADY\n"
            "UVM_INFO: 31 of 31 functional checks passed\n"
            "UVM_ERROR :    0"),
        root_cause="The MASTER (driver) deasserts AWVALID before AWREADY is "
                   "sampled high, violating the VALID-stability rule. The DUT "
                   "is correct; the testbench driver is not.",
        # It has to name master/driver-side VALID stability, not a slave defect.
        must=[["master", "driver", "testbench"], ["awvalid", "valid"],
              ["stable", "deassert", "held", "hold", "drop"]],
        must_not=["slave is wrong", "dut defect in the slave"],
    ),
    dict(
        id="BUG-002",
        signature="ASSERT:a_bvalid_not_early",
        context=(
            "[335000] %Error: axi4lite_if.sv:125: Assertion failed in "
            "sanity_tb.dut.u_chk.a_bvalid_not_early: BVALID asserted before both "
            "AW and W were accepted\n"
            "RESULT: all 31 checks passed"),
        root_cause="The slave asserts BVALID after AW is accepted but before W "
                   "is accepted. The write-commit condition tests only the AW "
                   "half.",
        must=[["bvalid", "b channel", "write response"],
              ["w ", "wvalid", "write data", "both"],
              ["accept", "before", "early", "premature"]],
        must_not=[],
    ),
    dict(
        id="BUG-003",
        signature="UVM:SB:RDATA mismatch on READ REGION_MEM addr=<H> : got <H> expected <H>",
        context=(
            "UVM_ERROR @ 1755 NS: uvm_test_top.env.sb [SB] RDATA mismatch on "
            "READ  REGION_MEM  addr=0x00001008 : got 0xffffffff expected 0xff22ff44\n"
            "UVM_ERROR @ 2100 NS: uvm_test_top.env.sb [SB] RDATA mismatch on "
            "READ  REGION_MEM  addr=0x0000100c : got 0xaabbccdd expected 0xaa2233dd\n"
            "preceding writes used WSTRB values 0101 and 0110"),
        root_cause="The memory slave ignores WSTRB and writes all four bytes on "
                   "every write.",
        must=[["wstrb", "byte enable", "strobe", "byte lane"],
              ["ignor", "not honour", "not honor", "all four", "all bytes",
               "entire word", "whole word", "unconditional"]],
        must_not=[],
    ),
    dict(
        id="BUG-004",
        signature="UVM:uvm_reg_bit_bash_seq:Writing a <N> in bit #<N> of register "
                  "INT_STATUS with initial value <H> yielded <H> instead of <H>",
        context=(
            "UVM_ERROR @ 4210 NS: reporter [uvm_reg_bit_bash_seq] Writing a 1 in "
            "bit #0 of register \"regmodel.INT_STATUS\" with initial value 'h0 "
            "yielded 'h1 instead of 'h0\n"
            "UVM_ERROR @ 4260 NS: reporter [uvm_reg_bit_bash_seq] Writing a 1 in "
            "bit #1 of register \"regmodel.INT_STATUS\" with initial value 'h0 "
            "yielded 'h2 instead of 'h0"),
        root_cause="INT_STATUS is implemented as a plain RW register instead of "
                   "write-1-to-clear.",
        must=[["int_status", "register"],
              ["w1c", "write-1-to-clear", "write 1 to clear", "clear"],
              ["rw", "plain", "read-write", "storage", "normal write"]],
        must_not=[],
    ),
    dict(
        id="BUG-005",
        signature="CHECK:write <H> -> DECERR",
        context=(
            "FAIL   write 0x00001400 -> DECERR                   0x0         (expected 0x3)\n"
            "FAIL   read  0x00001400 -> DECERR                   0x0         (expected 0x3)\n"
            "FAIL   memory word 0 untouched by DECERR            0xbaadbaad  (expected 0x11112222)\n"
            "map: registers 0x0000-0x0FFF, memory 0x1000-0x13FF, "
            "0x1400 and above unmapped"),
        root_cause="The interconnect decodes on a single address bit instead of "
                   "comparing against the region limits, so 0x1400 is routed to "
                   "the memory slave instead of returning DECERR.",
        must=[["decode", "decod", "routing", "route", "address map"],
              ["bit", "range", "limit", "boundary", "comparison", "compare"]],
        must_not=[],
    ),
    dict(
        id="BUG-006",
        signature="CHECK:COUNTER reads exactly <N>",
        context=(
            "FAIL   COUNTER reads exactly 0                      0x000004a1  (expected 0x0)\n"
            "preceding write: CTRL = 0x00000002 (reset_stats=1, enable=0)\n"
            "UVM_ERROR @ 990 NS: uvm_test_top.env.sb [SB] RDATA mismatch on READ "
            "addr=0x00000018 : got 0x000004a1 expected 0x00000000"),
        root_cause="CTRL.reset_stats does not clear COUNTER.",
        must=[["reset_stats", "reset stats", "ctrl"],
              ["counter"],
              ["clear", "not clear", "no effect", "ignor", "reset"]],
        must_not=[],
    ),
]


def root_cause_only(answer):
    """The ROOT CAUSE line, without the NEXT STEP that follows it.

    Scoring the whole answer is too generous, and it was: the first
    sealed run scored BUG-005 CORRECT on the strength of the phrase
    "bit-sliced compare" appearing in its NEXT STEP, while its ROOT
    CAUSE line said something else entirely and something wrong.

    A triage note's next step is a suggestion; its root cause is a
    claim. Only the claim is scored, because only the claim is what the
    tool is being measured on.
    """
    text = answer
    for marker in ("NEXT STEP", "Next step", "next step"):
        i = text.find(marker)
        if i > 0:
            text = text[:i]
            break
    return text


def score(answer, bug):
    """Mechanical scoring of the ROOT CAUSE claim: every `must` group
    needs one of its synonyms.

    Deliberately keyword-based rather than judged by a person or by
    another model. A score that depends on who reads it is not a
    measurement, and a model grading a model is the thing this whole
    exercise exists to avoid.

    It is also COARSE, and docs/llm_triage.md says where it disagrees
    with a hand review and which of the two to believe. A mechanical
    score that is reproducible and a hand score that is right are worth
    publishing together; publishing only the flattering one is the
    failure automation_plan.md section 3 is about.

        correct    every group matched, nothing from must_not
        partial    at least half the groups matched
        wrong      fewer than half
    """
    text = root_cause_only(answer).lower()
    if any(bad.lower() in text for bad in bug["must_not"]):
        return "wrong"
    hits = sum(1 for group in bug["must"]
               if any(kw.lower() in text for kw in group))
    if hits == len(bug["must"]):
        return "correct"
    if hits * 2 >= len(bug["must"]):
        return "partial"
    return "wrong"


def measure(backend, refresh):
    rows = []
    for bug in BUGS:
        answer = hypothesise(bug["signature"], bug["context"],
                             backend=backend, refresh=refresh)
        verdict = score(answer, bug)
        rows.append(dict(id=bug["id"], verdict=verdict, answer=answer,
                         signature=bug["signature"], root_cause=bug["root_cause"]))
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--measure", action="store_true",
                    help="score the model against the six injected bugs")
    ap.add_argument("--backend", default="replay",
                    choices=["replay", "claude-cli", "anthropic"])
    ap.add_argument("--refresh", action="store_true",
                    help="re-ask even when a cached answer exists")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    if not args.measure:
        ap.print_help()
        return 0

    rows = measure(args.backend, args.refresh)
    counts = {"correct": 0, "partial": 0, "wrong": 0}
    for r in rows:
        counts[r["verdict"]] += 1

    if args.json:
        print(json.dumps(dict(backend=args.backend, counts=counts, rows=rows), indent=2))
        return 0

    print(f"LLM triage, measured against the six injected bugs  (backend: {args.backend})")
    print()
    for r in rows:
        print(f"  {r['id']}  {r['verdict'].upper():<8} {r['signature'][:56]}")
        for line in r["answer"].splitlines():
            if line.strip():
                print(f"            {line.strip()[:110]}")
        print(f"            actual: {r['root_cause'][:110]}")
        print()
    print(f"  correct {counts['correct']}/6   partial {counts['partial']}/6   "
          f"wrong {counts['wrong']}/6")
    return 0


if __name__ == "__main__":
    sys.exit(main())
