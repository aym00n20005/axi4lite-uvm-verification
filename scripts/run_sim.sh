#!/usr/bin/env bash
#=====================================================================
# run_sim.sh — local simulation for the non-UVM part of the project
#
#   ./scripts/run_sim.sh icarus       functional only, no assertions
#   ./scripts/run_sim.sh verilator    functional + SVA protocol checker
#   ./scripts/run_sim.sh verilator --coverage
#
# Simulator capability, measured 13 Aug 2026 — see docs/tooling_notes.md:
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
# That is what BUILD_DIR below is for — not an arbitrary choice.
#=====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/axi4lite_vbuild"
BUILD_DIR="${BUILD_DIR// /_}"

RTL="$ROOT/rtl/axi4lite_reg_slave.sv"
IF="$ROOT/tb/interface/axi4lite_if.sv"
BIND="$ROOT/tb/interface/axi4lite_checker_bind.sv"
TB="$ROOT/tb/sanity_tb.sv"

MODE="${1:-verilator}"
shift || true
COVERAGE=""
[[ "${1:-}" == "--coverage" ]] && COVERAGE="--coverage"

mkdir -p "$ROOT/sim"

case "$MODE" in

  icarus)
    echo "=== Icarus Verilog — functional only, checker NOT compiled ==="
    iverilog -g2012 -Wall -o "$ROOT/sim/sanity_tb.out" "$RTL" "$TB"
    ( cd "$ROOT" && vvp sim/sanity_tb.out )
    ;;

  verilator)
    echo "=== Verilator — functional + bound SVA protocol checker ==="
    rm -rf "$BUILD_DIR"
    verilator --binary --assert --timing -Wno-fatal -j 4 \
        $COVERAGE \
        --top-module sanity_tb \
        --Mdir "$BUILD_DIR" -o sanity_chk \
        "$RTL" "$IF" "$BIND" "$TB"
    ( cd "$ROOT" && "$BUILD_DIR/sanity_chk" )
    if [[ -n "$COVERAGE" ]]; then
        echo ""
        echo "=== Cover property results ==="
        # The simulation writes coverage.dat into the directory it ran in.
        verilator_coverage --annotate "$ROOT/sim/cov_annotated" \
                           "$ROOT/coverage.dat" 2>/dev/null \
            && mv "$ROOT/coverage.dat" "$ROOT/sim/" \
            || echo "(no coverage.dat produced)"
    fi
    ;;

  *)
    echo "usage: $0 [icarus|verilator] [--coverage]" >&2
    exit 2
    ;;
esac
