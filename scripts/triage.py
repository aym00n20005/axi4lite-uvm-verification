#!/usr/bin/env python3
"""triage.py -- what actually broke?

    make triage
    python3 scripts/triage.py results/20260906_225201
    python3 scripts/triage.py --llm            # advisory root-cause notes

docs/automation_plan.md T3.

A regression's output is a list of failed runs. That is not the
question anyone has. The question is "how many distinct things are
wrong, which of them are new, and which of them are not real" -- and
answering it is what a person otherwise spends an afternoon on, reading
two hundred logs to find three bugs.

FOUR ANSWERS, IN ORDER OF WHAT THEY ARE WORTH:

  clusters   failures grouped by parse_log's normalised signature.
             Two hundred failures are usually three bugs. This is the
             number that goes in the first sentence of a status update.

  new        signatures present now and absent from the previous run.
             A regression with fifty long-standing failures and one new
             one looks identical to a regression with fifty-one
             long-standing failures, unless something diffs them.

  flaky      the same test, the same code, different verdicts across
             seeds. A flaky test is worse than a failing one: it trains
             people to re-run instead of to look, and it hides the real
             failures behind noise.

  stale      MISSING imported runs. Not a failure and not a pass --
             nobody has run it. A regression that reports green while a
             test has not executed since August is reporting on the
             wrong thing.

The LLM layer is OFF by default and is advisory only. Its measured hit
rate is in docs/llm_triage.md -- see scripts/llm_triage.py for why the
measurement is the point rather than the feature.
"""

import argparse
import json
import pathlib
import sys
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"


def load(path):
    p = pathlib.Path(path)
    if p.is_dir():
        p = p / "results.json"
    if not p.exists():
        sys.exit(f"triage: no results at {p}")
    return json.loads(p.read_text())


def previous_run(current_stamp):
    """The most recent regression before this one."""
    if not RESULTS.exists():
        return None
    stamps = sorted(d.name for d in RESULTS.iterdir()
                    if d.is_dir() and (d / "results.json").exists()
                    and d.name != "latest")
    before = [s for s in stamps if s < current_stamp]
    if not before:
        return None
    return json.loads((RESULTS / before[-1] / "results.json").read_text())


def cluster(runs):
    """signature -> the runs that produced it."""
    by_sig = defaultdict(list)
    for r in runs:
        for sig in r["signatures"]:
            by_sig[sig].append(r)
    return by_sig


def find_flaky(runs):
    """Same test name, more than one distinct verdict across its seeds.

    Deliberately keyed on the test alone and not on (test, seed): a test
    that passes on seed 1 and fails on seed 7 is EXACTLY the case this
    is looking for. Two different verdicts from the same code is either
    a real seed-dependent bug or a race in the testbench, and both are
    worth more attention than a test that fails every time.
    """
    verdicts = defaultdict(set)
    for r in runs:
        if r["status"] == "MISSING":
            continue
        verdicts[r["test"]].add(r["status"])
    return {t: sorted(v) for t, v in verdicts.items() if len(v) > 1}


def report(data, prev, use_llm=False, markdown=False):
    runs = data["runs"]
    failed = [r for r in runs if r["status"] in ("FAIL", "INCOMPLETE")]
    missing = [r for r in runs if r["status"] == "MISSING"]
    clusters = cluster(failed)
    flaky = find_flaky(runs)

    prev_sigs = set()
    if prev:
        for r in prev["runs"]:
            prev_sigs.update(r["signatures"])
    new_sigs = sorted(set(clusters) - prev_sigs) if prev else []
    fixed_sigs = sorted(prev_sigs - set(clusters)) if prev else []

    out = []
    h1 = "# " if markdown else ""
    out.append(f"{h1}Triage — regression {data['timestamp']}")
    out.append("")

    # The headline sentence, in the shape a status update wants.
    parts = [f"{len(runs)} runs",
             f"{data['counts'].get('PASS', 0)} passed",
             f"{len(failed)} failed"]
    if missing:
        parts.append(f"{len(missing)} not run")
    out.append("  " + ", ".join(parts) + ".")
    if failed:
        s = (f"  {len(failed)} failing runs are **{len(clusters)} distinct failures**"
             if markdown else
             f"  {len(failed)} failing runs are {len(clusters)} distinct failures")
        if prev:
            s += f", {len(new_sigs)} new since {prev['timestamp']}"
        out.append(s + ".")
    if flaky:
        out.append(f"  {len(flaky)} flaky test(s).")
    out.append("")

    if clusters:
        out.append("## Distinct failures" if markdown else "-- distinct failures --")
        out.append("")
        ranked = sorted(clusters.items(),
                        key=lambda kv: (-len({r['test'] for r in kv[1]}), -len(kv[1])))
        for i, (sig, rs) in enumerate(ranked, 1):
            tests = sorted({r["test"] for r in rs})
            flag = "  [NEW]" if sig in new_sigs else ""
            out.append(f"  {i}. {sig}{flag}")
            out.append(f"       {len(rs)} run(s), {len(tests)} test(s): {', '.join(tests)}")
            seeds = sorted(r["seed"] for r in rs if r["seed"] is not None)
            if seeds:
                out.append(f"       seeds: {', '.join(str(s) for s in seeds)}")
            sample = next((f["raw"] for r in rs for f in r["findings"]
                           if f["signature"] == sig), "")
            if sample:
                out.append(f"       first: {sample[:150]}")
            out.append(f"       log:   {rs[0]['log']}")
            out.append("")

    if flaky:
        out.append("## Flaky" if markdown else "-- flaky --")
        out.append("")
        for t, verdicts in sorted(flaky.items()):
            per_seed = [(r["seed"], r["status"]) for r in runs if r["test"] == t]
            out.append(f"  {t}: {' / '.join(verdicts)}")
            out.append("       " + ", ".join(f"seed {s}={v}" for s, v in sorted(
                per_seed, key=lambda x: (x[0] is None, x[0]))))
            out.append("")

    if fixed_sigs:
        out.append("## Gone since the previous run" if markdown else "-- gone since last run --")
        out.append("")
        for sig in fixed_sigs:
            out.append(f"  {sig}")
        out.append("")

    if missing:
        out.append("## Not run" if markdown else "-- not run --")
        out.append("")
        for r in missing:
            out.append(f"  {r['test']}")
            out.append(f"       {r.get('note', 'no log')}")
        out.append("")

    if not clusters and not flaky:
        out.append("  No failures to triage." if not missing else
                   "  No failures among the runs that executed.")
        out.append("")

    #---------------------------------------------------------------- A1
    if use_llm and clusters:
        try:
            import llm_triage
        except ImportError:
            out.append("  (--llm requested but scripts/llm_triage.py is missing)")
        else:
            out.append("## Root-cause hypotheses — ADVISORY" if markdown
                       else "-- root-cause hypotheses (ADVISORY) --")
            out.append("")
            out.append("  Generated by a language model. It annotates; it decides nothing.")
            out.append("  Measured hit rate against the six injected bugs: docs/llm_triage.md")
            out.append("")
            for sig, rs in sorted(clusters.items()):
                ctx = "\n".join(f["raw"] for r in rs for f in r["findings"]
                                if f["signature"] == sig)[:2000]
                note = llm_triage.hypothesise(sig, ctx)
                out.append(f"  {sig}")
                for line in note.splitlines():
                    out.append(f"       {line}")
                out.append("")

    return "\n".join(out), len(clusters)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("results", nargs="?", default=str(RESULTS / "latest"))
    ap.add_argument("--llm", action="store_true",
                    help="add advisory LLM root-cause notes (see docs/llm_triage.md)")
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--out", help="write the report to a file as well as stdout")
    args = ap.parse_args()

    data = load(args.results)
    prev = previous_run(data["timestamp"])
    text, n_clusters = report(data, prev, use_llm=args.llm, markdown=args.markdown)

    print(text)
    if args.out:
        pathlib.Path(args.out).write_text(text + "\n")
        print(f"  written to {args.out}")

    return 1 if n_clusters else 0


if __name__ == "__main__":
    sys.exit(main())
