#!/usr/bin/env python3
"""run_regression.py -- the regression, in parallel, with a verdict.

    make regression
    python3 scripts/run_regression.py --jobs 8
    python3 scripts/run_regression.py --only sanity_rand_tb

docs/automation_plan.md T1. Reads scripts/testlist.yaml, launches every
local run in parallel, imports the UVM logs that cannot be launched from
here, and writes results/<timestamp>/results.json plus a summary table.

Exit code is non-zero if anything failed, so this is usable as a gate.

TWO RUNNERS, ONE RESULT FORMAT.

    local     Verilator, launched here, one process per seed.
    imported  UVM on EDA Playground. Cannot be launched -- no local
              simulator runs UVM -- so its LOG is read instead and
              parsed by exactly the same code.

A missing imported log is reported as MISSING, not as a failure and not
as a pass. It is neither: nobody has run it yet. Calling that a pass is
how a regression reports green on a test that has not executed since
August, and calling it a failure trains people to ignore the column.
"""

import argparse
import concurrent.futures
import datetime
import json
import pathlib
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import parse_log

try:
    import yaml
except ImportError:
    sys.exit("run_regression: PyYAML missing -- run 'make setup'")

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"


def load_testlist(path):
    doc = yaml.safe_load(pathlib.Path(path).read_text())
    defaults = doc.get("defaults", {})
    runs = []
    for t in doc["tests"]:
        if t["runner"] == "local":
            for seed in t.get("seeds", [0]):
                runs.append(dict(
                    test=t["name"], runner="local", target=t["target"], seed=seed,
                    timeout=t.get("timeout", defaults.get("timeout", 600)),
                    n=t.get("n", defaults.get("n", 400)),
                    expect=t.get("expect", "pass"), features=t.get("features", []),
                ))
        else:
            runs.append(dict(
                test=t["name"], runner="imported", log=t["log"],
                bundle=t.get("bundle", ""), seed=None,
                timeout=t.get("timeout", defaults.get("timeout", 600)),
                expect=t.get("expect", "pass"), features=t.get("features", []),
            ))
    return runs


def build_targets(targets):
    """Compile each distinct target ONCE, before any of them runs.

    The first real use of this runner found the reason: ten seeds of
    sanity_rand_tb launched in parallel all built into the same
    directory, each starting with `rm -rf`, and five of the ten died on
    a Makefile another job had just deleted. The runner reported them as
    INCOMPLETE, which was correct and was also the first thing it ever
    caught -- in the flow rather than in the design.

    Compiling once is what a regression should do regardless: the binary
    does not depend on the seed, and the seed is a plusarg.
    """
    print(f"  building {len(targets)} target(s): {', '.join(sorted(targets))}")
    for t in sorted(targets):
        p = subprocess.run(
            [str(ROOT / "scripts" / "run_sim.sh"), "verilator", t, "--build-only"],
            cwd=str(ROOT), capture_output=True, text=True, timeout=900)
        if p.returncode != 0:
            print(p.stdout[-3000:])
            print(p.stderr[-3000:])
            sys.exit(f"run_regression: build failed for target '{t}'")
    print()


def run_local(run, outdir):
    """One Verilator run against an already-built binary. Its whole
    stdout is kept -- a failure is only debuggable from the log, and a
    regression that discards logs makes every failure a re-run."""
    cmd = [str(ROOT / "scripts" / "run_sim.sh"), "verilator", run["target"], "--no-build"]
    if run["target"] == "rand":
        cmd += [f"+seed={run['seed']}", f"+n={run['n']}"]

    started = time.time()
    try:
        p = subprocess.run(cmd, cwd=str(ROOT), capture_output=True,
                           text=True, timeout=run["timeout"])
        text, rc, timed_out = p.stdout + p.stderr, p.returncode, False
    except subprocess.TimeoutExpired as e:
        text = (e.stdout or "") + (e.stderr or "")
        if isinstance(text, bytes):
            text = text.decode(errors="replace")
        text += f"\n%Fatal: run_regression timeout after {run['timeout']}s\n"
        rc, timed_out = 124, True

    elapsed = time.time() - started
    tag = f"{run['test']}_seed{run['seed']}"
    logfile = outdir / f"{tag}.log"
    logfile.write_text(text)

    r = parse_log.parse(text, name=tag)
    r.update(test=run["test"], seed=run["seed"], runner="local",
             exit_code=rc, seconds=round(elapsed, 2),
             log=str(logfile.relative_to(ROOT)), features=run["features"],
             timed_out=timed_out)
    if timed_out:
        r["status"] = "FAIL"
        if "TIMEOUT" not in r["signatures"]:
            r["signatures"].append(f"TIMEOUT:{run['timeout']}s")
    return r


def run_imported(run, outdir):
    """A UVM log somebody produced on EDA Playground."""
    src = ROOT / run["log"]
    tag = run["test"]

    if not src.exists():
        return dict(name=tag, test=run["test"], seed=None, runner="imported",
                    status="MISSING", completed=False,
                    counts=dict(uvm_error=0, uvm_fatal=0, uvm_warning=0),
                    checks=0, passed=0, failed=0, signatures=[], findings=[],
                    exit_code=None, seconds=0.0, log=run["log"],
                    features=run["features"],
                    note=f"not run yet -- make playground PLAY={run['bundle']}, "
                         f"paste, run, then make import-log LOG={run['log']} TEST={tag}")

    text = src.read_text(errors="replace")
    (outdir / f"{tag}.log").write_text(text)
    r = parse_log.parse(text, name=tag)
    r.update(test=run["test"], seed=None, runner="imported", exit_code=None,
             seconds=0.0, log=run["log"], features=run["features"],
             imported_at=datetime.datetime.fromtimestamp(
                 src.stat().st_mtime).isoformat(timespec="seconds"))
    return r


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--testlist", default=str(ROOT / "scripts" / "testlist.yaml"))
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--only", action="append", default=[],
                    help="run only these test names (repeatable)")
    ap.add_argument("--local-only", action="store_true",
                    help="skip imported UVM logs")
    args = ap.parse_args()

    runs = load_testlist(args.testlist)
    if args.only:
        runs = [r for r in runs if r["test"] in args.only]
    if args.local_only:
        runs = [r for r in runs if r["runner"] == "local"]
    if not runs:
        sys.exit("run_regression: nothing to run")

    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    outdir = RESULTS / stamp
    outdir.mkdir(parents=True, exist_ok=True)

    print(f"regression {stamp}: {len(runs)} runs, {args.jobs} jobs")
    print()

    results = []
    local = [r for r in runs if r["runner"] == "local"]
    imported = [r for r in runs if r["runner"] == "imported"]

    started = time.time()
    if local:
        build_targets({r["target"] for r in local})
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run_local, r, outdir): r for r in local}
        for f in concurrent.futures.as_completed(futures):
            results.append(f.result())
    for r in imported:
        results.append(run_imported(r, outdir))
    elapsed = time.time() - started

    results.sort(key=lambda r: (r["test"], r["seed"] if r["seed"] is not None else -1))

    #-------------------------------------------------------------- table
    mark = {"PASS": "ok  ", "FAIL": "FAIL", "INCOMPLETE": "????", "MISSING": "--  "}
    print(f"  {'':4} {'test':<24} {'seed':>5}  {'checks':>10}  {'time':>7}  signatures")
    print(f"  {'-'*4} {'-'*24} {'-'*5}  {'-'*10}  {'-'*7}  {'-'*30}")
    for r in results:
        seed = "" if r["seed"] is None else str(r["seed"])
        checks = f"{r['passed']}/{r['checks']}" if r["checks"] else "-"
        secs = f"{r['seconds']:.1f}s" if r["seconds"] else "-"
        sigs = ", ".join(r["signatures"][:2]) if r["signatures"] else ""
        if len(r["signatures"]) > 2:
            sigs += f" (+{len(r['signatures']) - 2})"
        print(f"  {mark[r['status']]} {r['test']:<24} {seed:>5}  {checks:>10}  {secs:>7}  {sigs}")
        if r["status"] == "MISSING":
            print(f"       {r['note']}")

    by_status = {}
    for r in results:
        by_status[r["status"]] = by_status.get(r["status"], 0) + 1

    total_checks = sum(r["checks"] for r in results)
    total_passed = sum(r["passed"] for r in results)

    print()
    print(f"  {len(results)} runs in {elapsed:.1f}s: " +
          ", ".join(f"{n} {s}" for s, n in sorted(by_status.items())))
    print(f"  {total_passed}/{total_checks} checks passed")

    #--------------------------------------------------------------- json
    summary = dict(
        timestamp=stamp,
        seconds=round(elapsed, 2),
        jobs=args.jobs,
        counts=by_status,
        checks=dict(total=total_checks, passed=total_passed),
        runs=results,
    )
    jf = outdir / "results.json"
    jf.write_text(json.dumps(summary, indent=2))

    # A stable path for the latest run, so triage.py and the report
    # scripts have something to point at that does not change name.
    latest = RESULTS / "latest"
    if latest.is_symlink() or latest.exists():
        latest.unlink()
    latest.symlink_to(outdir.name)

    print(f"  {jf.relative_to(ROOT)}")
    print()

    # MISSING is not a failure -- nobody has run it. It is also not a
    # pass. The exit code covers real failures only, so a clean local
    # regression is still green while a UVM log is outstanding, and the
    # table above is where the outstanding one is visible.
    bad = by_status.get("FAIL", 0) + by_status.get("INCOMPLETE", 0)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
