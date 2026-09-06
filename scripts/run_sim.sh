#!/usr/bin/env bash
#=====================================================================
# run_sim.sh — local simulation for the non-UVM part of the project
#
#   ./scripts/run_sim.sh                        verilator, both benches
#   ./scripts/run_sim.sh verilator reg          register slave only
#   ./scripts/run_sim.sh icarus  mem            memory slave, no assertions
#   ./scripts/run_sim.sh verilator all --coverage
#   ./scripts/run_sim.sh verilator sys           interconnect + both slaves
#   ./scripts/run_sim.sh verilator rand +seed=7  seeded random, all channels
#
# Simulator capability, measured 16 Aug 2026 — see docs/tooling_notes.md:
#
#   Icarus 13.0     cannot do this checker at all.  Concurrent assertions
#                   are unsupported ("sorry: concurrent_assertion_item"),
#                   and it cannot parse the interface's clocking blocks.
#                   Useful only as a fast functional smoke run.
#
#   Verilator 5.050 runs the entire checker, and parses axi4lite_if.sv
#                   including the clocking blocks.  This is the local
#                   assertion flow.  It has NO UVM support, so the UVM
#                   environment still belongs on EDA Playground.
#
# Verilator's generated Makefile cannot build in a directory whose path
# contains spaces, and this project lives in "AXI-4 Lite Project".  Source
# paths with spaces are fine; only the build directory has to be moved.
# That is what BUILD_ROOT below is for — not an arbitrary choice.
#
# Both RTL files are always compiled, and both bind files included, even
# when only one bench runs. Local builds have both slaves available, so
# both binds resolve. The EDA Playground bundles are the case that needs
# the binds split per slave -- see the Makefile's playground target.
#=====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${TMPDIR:-/tmp}"
BUILD_ROOT="${BUILD_ROOT%/}/axi4lite_vbuild"
BUILD_ROOT="${BUILD_ROOT// /_}"

# The generated register-map package comes FIRST: axi4lite_reg_slave
# imports it. Regenerate with `make regmap` after editing regmap.yaml.
RTL=( "$ROOT/rtl/gen/axi4lite_reg_pkg.sv" \
      "$ROOT/rtl/axi4lite_reg_slave.sv" "$ROOT/rtl/axi4lite_mem_slave.sv" \
      "$ROOT/rtl/axi4lite_interconnect.sv" )
IF="$ROOT/tb/interface/axi4lite_if.sv"
BIND_REG="$ROOT/tb/interface/axi4lite_reg_bind.sv"
BIND_MEM="$ROOT/tb/interface/axi4lite_mem_bind.sv"
BIND_SYS="$ROOT/tb/interface/axi4lite_sys_bind.sv"

TB_reg="$ROOT/tb/sanity_tb.sv"
TB_mem="$ROOT/tb/sanity_mem_tb.sv"
TB_sys="$ROOT/tb/sanity_sys_tb.sv"
TB_rand="$ROOT/tb/sanity_rand_tb.sv"
TOP_reg="sanity_tb"
TOP_mem="sanity_mem_tb"
TOP_sys="sanity_sys_tb"
TOP_rand="sanity_rand_tb"

MODE="${1:-verilator}"
WHICH="${2:-all}"
shift 2 2>/dev/null || true
COVERAGE=""
# Anything left over is passed to the simulation binary. That is how a
# seed reaches sanity_rand_tb: run_regression.py launches the same
# binary N times with +seed=N.
PLUSARGS=()
for a in "$@"; do
    if [[ "$a" == "--coverage" ]]; then COVERAGE="--coverage-user"; else PLUSARGS+=("$a"); fi
done

case "$WHICH" in
  reg)  TARGETS=(reg) ;;
  mem)  TARGETS=(mem) ;;
  sys)  TARGETS=(sys) ;;
  rand) TARGETS=(rand) ;;
  all)  TARGETS=(reg mem sys) ;;
  *)    echo "usage: $0 [icarus|verilator] [reg|mem|sys|rand|all] [--coverage] [+plusargs...]" >&2; exit 2 ;;
esac

mkdir -p "$ROOT/sim"
FAILED=0

for T in "${TARGETS[@]}"; do
    TB_VAR="TB_$T";  TB="${!TB_VAR}"
    TOP_VAR="TOP_$T"; TOP="${!TOP_VAR}"

    echo ""
    echo "######################################################################"
    echo "# $TOP  —  $MODE"
    echo "######################################################################"

    case "$MODE" in

      icarus)
        # Checker and interface excluded: Icarus supports neither.
        iverilog -g2012 -Wall -o "$ROOT/sim/$TOP.out" "${RTL[@]}" "$TB"
        ( cd "$ROOT" && vvp "sim/$TOP.out" "${PLUSARGS[@]+"${PLUSARGS[@]}"}" ) || FAILED=1
        ;;

      verilator)
        BUILD="$BUILD_ROOT/$TOP"
        rm -rf "$BUILD"
        # Verilator creates only the final --Mdir level, so after a
        # `make clean` has removed BUILD_ROOT entirely it cannot create
        # BUILD_ROOT/$TOP. Make the parent ourselves.
        mkdir -p "$BUILD"
        verilator --binary --assert --timing -Wno-fatal -j 4 \
            ${COVERAGE:+$COVERAGE} \
            --top-module "$TOP" \
            --Mdir "$BUILD" -o "$TOP" \
            "${RTL[@]}" "$IF" "$BIND_REG" "$BIND_MEM" "$BIND_SYS" "$TB"
        ( cd "$ROOT/sim" && "$BUILD/$TOP" "${PLUSARGS[@]+"${PLUSARGS[@]}"}" ) || FAILED=1
        # Verilator drops coverage.dat in the run directory. Both benches
        # run there, so keep them apart or the second overwrites the first.
        if [[ -n "$COVERAGE" && -f "$ROOT/sim/coverage.dat" ]]; then
            mv "$ROOT/sim/coverage.dat" "$ROOT/sim/coverage_$TOP.dat"
        fi
        ;;

      *)
        echo "usage: $0 [icarus|verilator] [reg|mem|all] [--coverage]" >&2
        exit 2
        ;;
    esac
done

if [[ -n "$COVERAGE" ]]; then
    for T in "${TARGETS[@]}"; do
        TOP_VAR="TOP_$T"; TOP="${!TOP_VAR}"
        DAT="$ROOT/sim/coverage_$TOP.dat"
        [[ -f "$DAT" ]] || continue
        echo ""
        echo "=== cover properties — $TOP ==="
        # Split by checker INSTANCE, not just by cover point. On a system
        # build there are three, and the difference between them is the
        # result: DECERR appears at the master port and nowhere else,
        # because spec section 4 says the interconnect produces it and no
        # slave can. A single collapsed column would hide exactly that.
        #
        # Verilator merges instances that share a parameterisation and
        # prints the common prefix with a '*' -- so the two CHECK_ALIGN=1
        # slave binds arrive as one row, and the CHECK_ALIGN=0 master-port
        # bind as another. That merge is the tool's, not this script's.
        # Verilator's coverage key is a set of \001-separated fields,
        # each introduced by a one-letter tag: 'o' is the cover point's
        # name and 'h' its instance path. The separator is invisible in a
        # terminal, which makes the key look like one run-on string and
        # invites parsing it by hand -- don't.
        awk -F"'" '/^C/ {
                     n = split($2, f, "\001");
                     pt = ""; hier = "";
                     for (k = 1; k <= n; k++) {
                       if (substr(f[k], 1, 1) == "o") pt   = substr(f[k], 2);
                       if (substr(f[k], 1, 1) == "h") hier = substr(f[k], 2);
                     }
                     if (pt == "") next;
                     inst = hier;
                     sub(/\.[^.]+$/, "", inst);       # drop the trailing .c_<name>
                     printf "  %-22s %-30s %d\n", pt, inst, $3 + 0;
                   }' "$DAT" | sort
    done
fi

exit $FAILED
