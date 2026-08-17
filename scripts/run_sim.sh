#!/usr/bin/env bash
#=====================================================================
# run_sim.sh — local simulation for the non-UVM part of the project
#
#   ./scripts/run_sim.sh                        verilator, both benches
#   ./scripts/run_sim.sh verilator reg          register slave only
#   ./scripts/run_sim.sh icarus  mem            memory slave, no assertions
#   ./scripts/run_sim.sh verilator all --coverage
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
# Both RTL files are always compiled, even when only one bench runs: the
# bind file names both slave modules, and binding to a module that is not
# in the design is an elaboration error.
#=====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${TMPDIR:-/tmp}"
BUILD_ROOT="${BUILD_ROOT%/}/axi4lite_vbuild"
BUILD_ROOT="${BUILD_ROOT// /_}"

RTL=( "$ROOT/rtl/axi4lite_reg_slave.sv" "$ROOT/rtl/axi4lite_mem_slave.sv" )
IF="$ROOT/tb/interface/axi4lite_if.sv"
BIND="$ROOT/tb/interface/axi4lite_checker_bind.sv"

TB_reg="$ROOT/tb/sanity_tb.sv"
TB_mem="$ROOT/tb/sanity_mem_tb.sv"
TOP_reg="sanity_tb"
TOP_mem="sanity_mem_tb"

MODE="${1:-verilator}"
WHICH="${2:-all}"
COVERAGE=""
[[ "${3:-}" == "--coverage" ]] && COVERAGE="--coverage-user"

case "$WHICH" in
  reg) TARGETS=(reg) ;;
  mem) TARGETS=(mem) ;;
  all) TARGETS=(reg mem) ;;
  *)   echo "usage: $0 [icarus|verilator] [reg|mem|all] [--coverage]" >&2; exit 2 ;;
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
        ( cd "$ROOT" && vvp "sim/$TOP.out" ) || FAILED=1
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
            "${RTL[@]}" "$IF" "$BIND" "$TB"
        ( cd "$ROOT/sim" && "$BUILD/$TOP" ) || FAILED=1
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
        awk -F"'" '/^C/ {print}' "$DAT" | sed "s/.*c_/c_/" | sort
    done
fi

exit $FAILED
