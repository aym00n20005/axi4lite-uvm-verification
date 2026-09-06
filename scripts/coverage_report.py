#!/usr/bin/env python3
"""coverage_report.py -- what is covered, by whom, and since when.

    make coverage
    python3 scripts/coverage_report.py --run
    python3 scripts/coverage_report.py --no-run     # parse what is there

docs/automation_plan.md T5.

TWO SOURCES, BECAUSE THIS PROJECT HAS TWO COVERAGE MECHANISMS AND
NEITHER ONE IS AVAILABLE EVERYWHERE.

  cover properties      Verilator's --coverage-user, from the local
                        benches. Per checker INSTANCE, which is the
                        interesting part on a system build: DECERR
                        appears at the master port and nowhere else,
                        because spec section 4 says the interconnect
                        produces it and no slave can.

  functional coverage   the hand tally in tb/env/axi_coverage.sv,
                        scraped out of a UVM log. NOT the covergroups:
                        Xcelium needs coverage enabled at elaboration
                        and EDA Playground's command line cannot pass
                        it, so get_inst_coverage() returns a silent
                        0.00% there. The tally is the number that
                        survives, and it reports MISSING BINS BY NAME,
                        which a percentage cannot.

THE TREND IS THE OTHER HALF.

Every run appends to results/coverage_history.json, keyed by commit. A
bin that has been at zero for several runs is either a stimulus gap
somebody should close or a structural fact somebody should write down --
and the difference between those two is the entire content of
docs/coverage_status.md. Without a history there is no way to tell a bin
that just regressed from one that was never reachable.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
SIM = ROOT / "sim"
RESULTS = ROOT / "results"
HISTORY = RESULTS / "coverage_history.json"
OUT = ROOT / "docs" / "coverage_report.md"

# Verilator writes a \001-separated key; 'o' is the cover point name and
# 'h' its instance path. See scripts/run_sim.sh for the same parse and
# the reason it is not done by hand.
COV_LINE = re.compile(r"^C '(?P<key>.*)' (?P<count>\d+)\s*$")

# The UVM hand tally, from axi_coverage::report_tally.
#   [COV]     cg_wstrb                16/16  100.00%
#   [COV]         missing: 0000 0001
TALLY = re.compile(r"\[COV\]\s+(?P<group>cg_\w+)\s+(?P<hit>\d+)/(?P<total>\d+)\s+(?P<pct>[\d.]+)%")
MISSING = re.compile(r"\[COV\]\s+missing:\s*(?P<bins>.+?)\s*$")
SAMPLED = re.compile(r"functional coverage over (?P<n>\d+) observed transactions and (?P<r>\d+) reset events")


def parse_verilator(dat):
    """coverage.dat -> {(point, instance): count}"""
    out = {}
    for line in dat.read_text(errors="replace").splitlines():
        m = COV_LINE.match(line)
        if not m:
            continue
        point = inst = ""
        for field in m.group("key").split("\001"):
            if field.startswith("o"):
                point = field[1:]
            elif field.startswith("h"):
                inst = field[1:]
        if not point:
            continue
        inst = re.sub(r"\.[^.]+$", "", inst)      # drop the trailing .c_<name>
        out[(point, inst)] = int(m.group("count"))
    return out


def parse_uvm_tally(text):
    """A UVM log -> {group: dict(hit, total, pct, missing)}"""
    groups = {}
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = TALLY.search(line)
        if not m:
            continue
        entry = dict(hit=int(m.group("hit")), total=int(m.group("total")),
                     pct=float(m.group("pct")), missing=[])
        # "missing:" is emitted on the line after its group, if at all.
        if i + 1 < len(lines):
            mm = MISSING.search(lines[i + 1])
            if mm:
                entry["missing"] = mm.group("bins").split()
        groups[m.group("group")] = entry
    return groups


def run_coverage():
    for target in ("reg", "mem", "sys", "rand"):
        cmd = [str(ROOT / "scripts" / "run_sim.sh"), "verilator", target, "--coverage"]
        if target == "rand":
            cmd += ["+seed=1", "+n=800"]
        subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True, timeout=900)


def git_commit():
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                              cwd=str(ROOT), capture_output=True,
                              text=True).stdout.strip() or "unknown"
    except Exception:                                     # noqa: BLE001
        return "unknown"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--run", dest="run", action="store_true", default=True)
    ap.add_argument("--no-run", dest="run", action="store_false")
    ap.add_argument("--logs", default=str(SIM / "logs"))
    args = ap.parse_args()

    if args.run:
        print("  running the local benches with --coverage-user")
        run_coverage()

    #------------------------------------------------ cover properties
    per_bench = {}
    for dat in sorted(SIM.glob("coverage_*.dat")):
        bench = dat.stem.replace("coverage_", "")
        per_bench[bench] = parse_verilator(dat)

    # Union across benches, per instance -- a cover point is covered if
    # ANY bench reached it, which is what merging a regression means.
    merged = defaultdict(int)
    for counts in per_bench.values():
        for key, n in counts.items():
            merged[key] += n

    points = sorted({p for p, _ in merged})
    instances = sorted({i for _, i in merged})

    #--------------------------------------------- functional coverage
    uvm = {}
    logdir = pathlib.Path(args.logs)
    if logdir.exists():
        for log in sorted(logdir.glob("*.log")):
            text = log.read_text(errors="replace")
            tally = parse_uvm_tally(text)
            if tally:
                m = SAMPLED.search(text)
                uvm[log.stem] = dict(
                    groups=tally,
                    sampled=int(m.group("n")) if m else 0,
                    resets=int(m.group("r")) if m else 0)

    #------------------------------------------------------- the trend
    RESULTS.mkdir(parents=True, exist_ok=True)
    history = json.loads(HISTORY.read_text()) if HISTORY.exists() else []
    import datetime
    entry = dict(
        commit=git_commit(),
        date=datetime.datetime.now().isoformat(timespec="seconds"),
        cover_points={f"{p}|{i}": merged[(p, i)] for (p, i) in merged},
        functional={k: {g: v["hit"] / v["total"] * 100 if v["total"] else 0.0
                        for g, v in d["groups"].items()} for k, d in uvm.items()},
    )
    if not history or history[-1]["commit"] != entry["commit"] or \
       history[-1]["cover_points"] != entry["cover_points"]:
        history.append(entry)
        HISTORY.write_text(json.dumps(history, indent=2))

    # A cover point at zero for N consecutive entries is either a
    # stimulus gap or a structural fact. The report flags it; only a
    # person can say which, and coverage_status.md is where they say it.
    zero_runs = {}
    for key in entry["cover_points"]:
        n = 0
        for h in reversed(history):
            if h["cover_points"].get(key, 0) == 0:
                n += 1
            else:
                break
        if n:
            zero_runs[key] = n

    #------------------------------------------------------ the report
    L = []
    L.append("# Coverage — measured")
    L.append("")
    L.append(f"**GENERATED** by `scripts/coverage_report.py` at commit `{entry['commit']}`.")
    L.append("Do not edit — run `make coverage`. The *justifications* for anything")
    L.append("uncovered live in [coverage_status.md](coverage_status.md), which is written")
    L.append("by hand, because verification plan §5 requires a written reason and a")
    L.append("generator cannot supply one.")
    L.append("")

    #-- cover properties, one table per bench
    L.append("## Cover properties — SVA, local, Verilator")
    L.append("")
    L.append("One table per bench, and within a bench one column per checker **instance**.")
    L.append("Not merged into a single column, because the difference between the instances")
    L.append("is the result rather than noise: `c_resp_decerr` is non-zero at the master")
    L.append("port and zero at both slave ports, which is spec §4's claim — the interconnect")
    L.append("produces DECERR and no slave can — measured rather than argued.")
    L.append("")
    L.append("Instance paths are Verilator's own. A `u_*` prefix is its merge of two")
    L.append("instances that share a parameterisation, so on a system build the two")
    L.append("`CHECK_ALIGN=1` slave binds arrive as one column and the `CHECK_ALIGN=0`")
    L.append("master-port bind as another.")
    L.append("")

    for bench in sorted(per_bench):
        counts = per_bench[bench]
        b_points = sorted({p for p, _ in counts})
        b_insts = sorted({i for _, i in counts})
        if not b_points:
            continue
        # Strip the bench name, which is already the heading.
        short = {i: (i.split(".", 1)[1] if "." in i else i) for i in b_insts}
        L.append(f"### `{bench}`")
        L.append("")
        L.append("| Cover point | " + " | ".join(f"`{short[i]}`" for i in b_insts) + " |")
        L.append("|---" * (len(b_insts) + 1) + "|")
        for p in b_points:
            cells = []
            for i in b_insts:
                n = counts.get((p, i))
                cells.append("—" if n is None else (f"**{n}**" if n else "0"))
            L.append(f"| `{p}` | " + " | ".join(cells) + " |")
        L.append("")

    covered = sum(1 for p in points if any(merged.get((p, i), 0) for i in instances))
    L.append(f"**{covered} of {len(points)} cover properties are non-zero somewhere.**")
    L.append("")

    if zero_runs:
        L.append("### Zero, and for how long")
        L.append("")
        L.append("A count that has been zero across several runs is either a stimulus gap or a")
        L.append("structural fact. This table says *how long*; `coverage_status.md` says *which*.")
        L.append("")
        L.append("| Cover point | Instance | Consecutive runs at zero |")
        L.append("|---|---|---|")
        for key, n in sorted(zero_runs.items(), key=lambda kv: (-kv[1], kv[0])):
            point, inst = key.split("|", 1)
            L.append(f"| `{point}` | `{inst}` | {n} |")
        L.append("")

    #-- functional coverage
    L.append("## Functional coverage — UVM, imported from EDA Playground")
    L.append("")
    if not uvm:
        L.append("No UVM log has been imported yet.")
        L.append("")
        L.append("```bash")
        L.append("make playground PLAY=sys      # paste, run on Xcelium, save the log")
        L.append("make import-log LOG=sim/logs/sys.log TEST=axi_regression_test")
        L.append("make coverage")
        L.append("```")
        L.append("")
    else:
        for name, d in sorted(uvm.items()):
            L.append(f"### `{name}` — {d['sampled']} transactions, {d['resets']} reset events")
            L.append("")
            L.append("| Group | Bins | % | Missing |")
            L.append("|---|---|---|---|")
            for g, v in sorted(d["groups"].items()):
                miss = ", ".join(f"`{b}`" for b in v["missing"]) if v["missing"] else "—"
                mark = "" if v["hit"] == v["total"] else "**"
                L.append(f"| `{g}` | {mark}{v['hit']}/{v['total']}{mark} | {v['pct']:.2f}% | {miss} |")
            L.append("")
        L.append("These are the **hand tally**, not `get_inst_coverage()`. Xcelium requires")
        L.append("coverage enabled at elaboration (`-coverage functional`) and Playground's")
        L.append("command line cannot pass it, so the covergroups report a silent `0.00%`")
        L.append("there. The tally cannot be switched off by a tool flag, and it names the")
        L.append("missing bins — `cg_wstrb 12.50%` says how far there is to go, `missing:")
        L.append("0000 0001 0010` says what to write.")
        L.append("")

    #-- trend
    L.append("## Trend")
    L.append("")
    L.append(f"{len(history)} measurement(s) recorded in `results/coverage_history.json`.")
    L.append("")
    if len(history) > 1:
        L.append("| Commit | Date | Cover points non-zero |")
        L.append("|---|---|---|")
        for h in history[-10:]:
            nz = sum(1 for v in h["cover_points"].values() if v)
            L.append(f"| `{h['commit']}` | {h['date'][:16]} | {nz}/{len(h['cover_points'])} |")
        L.append("")

    OUT.write_text("\n".join(L) + "\n")

    print(f"  {covered}/{len(points)} cover properties non-zero, "
          f"{len(instances)} checker instance(s)")
    if uvm:
        for name, d in sorted(uvm.items()):
            closed = sum(1 for v in d["groups"].values() if v["hit"] == v["total"])
            print(f"  {name}: {closed}/{len(d['groups'])} functional groups closed")
    else:
        print("  no UVM log imported yet -- functional coverage section is empty")
    print(f"  {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
