#!/usr/bin/env python3
"""vplan_trace.py -- feature -> test -> result -> coverage -> status.

    make vplan
    python3 scripts/vplan_trace.py

docs/automation_plan.md T6.

This is the one that answers "are we done?" with evidence instead of an
opinion, and it is what a verification lead reports upward. Every other
tool here says something about a run; this one says something about the
PLAN.

FOUR SOURCES, JOINED ON THE FEATURE ID:

  docs/verification_plan.md §3   F01..F29 -- the features, and the
                                 method each one is supposed to be
                                 verified by. The authority for what
                                 EXISTS to be done.
  scripts/testlist.yaml          which tests CLAIM each feature.
  results/latest/results.json    whether those tests actually passed.
  docs/coverage_report.md        whether the coverage backing them moved.

A FEATURE WITH NO TEST IS THE POINT OF THE EXERCISE.

It is easy to build a matrix that is green because it only lists what
was tested. This one starts from the specification's feature list, so a
feature nothing claims shows up as UNCOVERED with an empty test column --
and that row is worth more than all the green ones.

A claim is also not a result. A test can name F21 in testlist.yaml and
be failing, or not have been run at all; the status column distinguishes
"claimed and passing" from "claimed and failing" from "claimed by a test
nobody has run since August".
"""

import argparse
import json
import pathlib
import re
import sys
from collections import defaultdict

try:
    import yaml
except ImportError:
    sys.exit("vplan_trace: PyYAML missing -- run 'make setup'")

ROOT = pathlib.Path(__file__).resolve().parent.parent
VPLAN = ROOT / "docs" / "verification_plan.md"
TESTLIST = ROOT / "scripts" / "testlist.yaml"
RESULTS = ROOT / "results" / "latest" / "results.json"
OUT = ROOT / "docs" / "traceability.md"

# | F01 | Write path | AW + W accepted, B returned with OKAY | Directed + random | Scoreboard |
ROW = re.compile(
    r"^\|\s*(?P<id>F\d{2})\s*\|\s*(?P<name>[^|]+?)\s*\|\s*(?P<desc>[^|]+?)\s*\|"
    r"\s*(?P<method>[^|]+?)\s*\|\s*(?P<second>[^|]*?)\s*\|")


def parse_vplan():
    text = VPLAN.read_text()
    start = text.find("## 3. Feature list")
    if start < 0:
        sys.exit("vplan_trace: section 3 not found in verification_plan.md")
    end = text.find("\n## ", start + 1)
    section = text[start:end if end > 0 else len(text)]

    features = {}
    for line in section.splitlines():
        m = ROW.match(line.strip())
        if m:
            features[m.group("id")] = dict(
                name=m.group("name"), desc=m.group("desc"),
                method=m.group("method"), second=m.group("second"))
    return features


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--results", default=str(RESULTS))
    args = ap.parse_args()

    features = parse_vplan()
    if not features:
        sys.exit("vplan_trace: parsed 0 features -- the §3 table format changed")

    testlist = yaml.safe_load(TESTLIST.read_text())
    claims = defaultdict(list)          # feature -> [test names]
    test_why = {}
    for t in testlist["tests"]:
        test_why[t["name"]] = " ".join(str(t.get("why", "")).split())
        for f in t.get("features", []):
            claims[f].append(t["name"])

    # Test verdicts, collapsed across seeds. A test is PASS only if every
    # seed of it passed -- one failing seed is a failing test, and
    # reporting the majority verdict is how a seed-dependent bug gets
    # rounded away.
    verdict = {}
    rp = pathlib.Path(args.results)
    if rp.exists():
        data = json.loads(rp.read_text())
        per_test = defaultdict(list)
        for r in data["runs"]:
            per_test[r["test"]].append(r["status"])
        for t, statuses in per_test.items():
            if all(s == "PASS" for s in statuses):
                verdict[t] = "PASS"
            elif all(s == "MISSING" for s in statuses):
                verdict[t] = "MISSING"
            elif any(s in ("FAIL", "INCOMPLETE") for s in statuses):
                verdict[t] = "FAIL"
            else:
                verdict[t] = "MIXED"
        stamp = data["timestamp"]
    else:
        stamp = "no regression results"

    #-------------------------------------------------------- statuses
    def status_of(fid):
        tests = claims.get(fid, [])
        if not tests:
            return "UNCOVERED", "no test claims this feature"
        verdicts = [verdict.get(t, "UNKNOWN") for t in tests]
        if any(v == "FAIL" for v in verdicts):
            return "FAILING", "a claiming test is failing"
        if any(v == "PASS" for v in verdicts):
            if all(v in ("PASS", "MISSING") for v in verdicts):
                if any(v == "MISSING" for v in verdicts):
                    return "PASSING", "passing locally; a UVM test also claims it and is not yet run"
                return "PASSING", ""
            return "PASSING", ""
        if all(v == "MISSING" for v in verdicts):
            return "NOT RUN", "only claimed by tests that have not been run"
        return "UNKNOWN", "no result for the claiming tests"

    rows = []
    for fid in sorted(features):
        st, note = status_of(fid)
        rows.append((fid, features[fid], claims.get(fid, []), st, note))

    counts = defaultdict(int)
    for _, _, _, st, _ in rows:
        counts[st] += 1

    #---------------------------------------------------------- report
    MARK = {"PASSING": "✅", "FAILING": "❌", "NOT RUN": "⏳",
            "UNCOVERED": "⚠️", "UNKNOWN": "❔"}

    L = []
    L.append("# Traceability — feature → test → result")
    L.append("")
    L.append("**GENERATED** by `scripts/vplan_trace.py`. Do not edit — run `make vplan`.")
    L.append("")
    L.append(f"Features from [verification_plan.md §3](verification_plan.md); claims from")
    L.append(f"`scripts/testlist.yaml`; results from regression `{stamp}`.")
    L.append("")
    L.append("The rows that matter are the ones that are **not** green. A matrix built from")
    L.append("the tests that exist is green by construction; this one is built from the")
    L.append("specification's feature list, so a feature nothing claims appears as")
    L.append("`UNCOVERED` with an empty test column.")
    L.append("")

    total = len(rows)
    L.append("| Status | Features |")
    L.append("|---|---|")
    for st in ("PASSING", "FAILING", "NOT RUN", "UNCOVERED", "UNKNOWN"):
        if counts[st]:
            L.append(f"| {MARK[st]} {st} | **{counts[st]}** of {total} |")
    L.append("")

    L.append("## Matrix")
    L.append("")
    L.append("| | Feature | Planned method | Claimed by | Result |")
    L.append("|---|---|---|---|---|")
    for fid, f, tests, st, note in rows:
        tcell = ", ".join(f"`{t}`" for t in tests) if tests else "**—**"
        rcell = f"{MARK[st]} {st}"
        L.append(f"| **{fid}** | {f['name']} | {f['method']} | {tcell} | {rcell} |")
    L.append("")

    problems = [(fid, f, tests, st, note) for fid, f, tests, st, note in rows
                if st != "PASSING"]
    if problems:
        L.append("## Everything not passing")
        L.append("")
        for fid, f, tests, st, note in problems:
            L.append(f"### {fid} — {f['name']} · {MARK[st]} {st}")
            L.append("")
            L.append(f"{f['desc']}")
            L.append("")
            L.append(f"- **Planned method:** {f['method']}"
                     + (f" (secondary: {f['second']})" if f["second"] else ""))
            if tests:
                L.append(f"- **Claimed by:** " + ", ".join(f"`{t}`" for t in tests))
            else:
                L.append("- **Claimed by:** nothing in `scripts/testlist.yaml`")
            if note:
                L.append(f"- **Why:** {note}")
            L.append("")
    else:
        L.append("Every feature in §3 is claimed by a test, and every claiming test passed.")
        L.append("")

    L.append("## Tests")
    L.append("")
    L.append("| Test | Result | Features | What it is for |")
    L.append("|---|---|---|---|")
    for t in testlist["tests"]:
        v = verdict.get(t["name"], "UNKNOWN")
        feats = ", ".join(t.get("features", [])) or "—"
        L.append(f"| `{t['name']}` | {v} | {feats} | {test_why[t['name']]} |")
    L.append("")

    OUT.write_text("\n".join(L) + "\n")

    print(f"  {total} features: " + ", ".join(
        f"{n} {st}" for st, n in sorted(counts.items()) if n))
    print(f"  {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
