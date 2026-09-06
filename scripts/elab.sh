#!/usr/bin/env bash
#=====================================================================
# elab.sh -- elaborate the UVM testbench locally, before pasting it
#            anywhere
#
#   ./scripts/elab.sh              every bundle
#   ./scripts/elab.sh smoke        one bundle
#
# WHY THIS EXISTS
#
# UVM cannot be simulated locally: Icarus and Verilator have no UVM
# support (docs/tooling_notes.md), so the only simulator that runs this
# environment is Xcelium on EDA Playground -- reached by clearing two
# panes and pasting into a browser. Every typo therefore costs a manual
# round trip, and the cost is paid in minutes, not seconds.
#
# slang is a conformant IEEE 1800-2017 front end. It cannot simulate,
# but it ELABORATES: ports, factory registrations, config_db type
# parameters, uvm_reg API misuse, every name and every type. That turns
# "paste it and find out" into a local check that runs in a fifth of a
# second, and leaves the browser for the one thing only a simulator can
# do -- actually running the test.
#
# WHAT IT CHECKS, EXACTLY
#
# The generated bundle, byte for byte -- the same file that goes into
# the Playground pane, not an approximation of it assembled a different
# way. If elaboration passes here and the paste fails there, the
# difference is the simulator, not the file list.
#
# TWO FLAGS THAT ARE NOT COSMETIC
#
#   --timescale=1ns/1ps
#       Only rtl/axi4lite_reg_slave.sv declares a `timescale. slang
#       reports the rest as an error ("design element does not have a
#       time scale defined but others in the design do") because a
#       partially-timescaled design has tool-dependent semantics.
#       Xcelium applies its own default and says nothing. This flag
#       states the default explicitly rather than inheriting one.
#
#   -I third_party/uvm-1.2/src
#       UVM 1.2, matching the CDNS-UVM-1.2 that Xcelium actually
#       supplies. Elaborating against 2020-2.0 would report errors
#       Xcelium will not, and miss ones it will.
#
# FIRST RUN, 6 SEPTEMBER: two errors, one defect, both in
# axi_transaction.sv's constraint block. See docs/bug_reports/BUG-010.md.
#=====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UVM_SRC="$ROOT/third_party/uvm-1.2/src"

if [[ ! -f "$UVM_SRC/uvm_pkg.sv" ]]; then
    echo "elab: UVM source missing -- run 'make setup' (or scripts/fetch_uvm.sh)" >&2
    exit 2
fi
if ! command -v slang >/dev/null 2>&1; then
    echo "elab: slang not found -- run 'make setup' (brew install svlang)" >&2
    exit 2
fi

ALL_BUNDLES=(hello rand_smoke smoke random mem)
if [[ $# -gt 0 ]]; then BUNDLES=("$@"); else BUNDLES=("${ALL_BUNDLES[@]}"); fi

FAILED=0
for B in "${BUNDLES[@]}"; do
    make -C "$ROOT" playground PLAY="$B" >/dev/null 2>&1 || {
        echo "elab: could not generate bundle '$B'" >&2; FAILED=1; continue; }

    TB="$ROOT/sim/playground_$B.sv"
    DESIGN="$ROOT/sim/playground_${B}_design.sv"

    # The top is the LAST module the testbench bundle declares. The
    # bundles differ -- 'mem' ends in tb_top_mem, the rest in tb_top --
    # and deriving it beats maintaining a second list that can drift
    # away from the Makefile's.
    TOP="$(grep -oE '^module +[A-Za-z_][A-Za-z0-9_]*' "$TB" | tail -1 | awk '{print $2}')"
    if [[ -z "$TOP" ]]; then
        echo "elab: no module found in $TB" >&2; FAILED=1; continue
    fi

    FILES=("$UVM_SRC/uvm_pkg.sv")
    [[ -f "$DESIGN" ]] && FILES+=("$DESIGN")
    FILES+=("$TB")

    OUT="$(slang --top "$TOP" --timescale=1ns/1ps -I "$UVM_SRC" "${FILES[@]}" 2>&1)"
    RC=$?

    # UVM 1.2 itself trips -Wempty-body twice (uvm_resource.svh:1666 and
    # uvm_sequencer.svh:171). Those are Accellera's, not ours, and there
    # is nothing to fix on our side -- so they are subtracted rather than
    # left to pad every report with the same two lines forever.
    SUMMARY="$(echo "$OUT" | grep -E '^Build (succeeded|failed)' | tail -1)"
    printf "  %-12s %-38s top=%s\n" "$B" "${SUMMARY:-no summary}" "$TOP"

    if [[ $RC -ne 0 ]]; then
        echo "$OUT" | grep -vE 'empty body|^ *(for\(first|while \(m_req)|^ *[~^ ]+$|^in file included from' | sed 's/^/      /'
        FAILED=1
    fi
done

if [[ $FAILED -ne 0 ]]; then
    echo ""
    echo "elab: FAILED -- do not paste into EDA Playground until this is clean"
    exit 1
fi
echo ""
echo "elab: all bundles elaborate -- 0 errors"
