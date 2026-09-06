#!/usr/bin/env bash
#=====================================================================
# run_formal.sh -- bounded model check of the register slave
#
#   make formal
#   ./formal/run_formal.sh 30        depth in cycles
#
# The SymbiYosys flow, without SymbiYosys: sby drives yosys-smtbmc, and
# yosys-smtbmc ships with Yosys, so calling it directly removes a
# source-build dependency and makes the flow visible in twenty lines
# instead of hidden behind a .sby file.
#
# async2sync IS REQUIRED, and the reason is the reset contract.
#
# Spec section 1 specifies an ASYNCHRONOUS assert, so the RTL uses
# `always_ff @(posedge ACLK or negedge ARESETn)` throughout and Yosys
# infers $adff cells. write_smt2 cannot model those:
#
#     ERROR: Unsupported cell type $adff -- please run `async2sync;
#     dffunmap` or `clk2fflogic` before `write_smt2`
#
# async2sync rewrites them as synchronous flops with the reset folded
# into the D input, which is sound for a bounded model check here
# BECAUSE of the other half of the same contract: section 1 also says
# the testbench shall only deassert ARESETn on an active clock edge, so
# the design never sees reset change between edges and the two forms are
# equivalent for it. A design with a genuinely asynchronous reset
# release would need clk2fflogic and a much slower proof.
#
# TWO PASSES, AND THE SECOND IS THE ONE PEOPLE SKIP.
#
#   bmc      no reachable state within N cycles violates any assertion.
#   cover    the interesting states ARE reachable within N cycles.
#
# Without the cover pass the proof can be vacuous: assertions that are
# never reached pass trivially, and a set of them will all pass on a
# design that does nothing. The property this whole file exists for --
# "an event and a W1C write to the same bit on the same cycle, set
# wins" -- proves nothing unless that collision is reachable, and
# fc_collision is what says it is.
#
# Depth: the default 25 cycles is enough for every rule here. All of
# them are one-cycle safety properties over state a handful of
# transactions can reach; none needs the counter to run to 0xFFFF,
# which is why f_counter_steps_by_one checks the STEP rather than the
# wrap.
#=====================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPTH="${1:-25}"
WORK="$ROOT/formal/build"
SOLVER="${SOLVER:-z3}"

command -v yosys       >/dev/null || { echo "formal: yosys not found -- run 'make setup'"; exit 2; }
command -v yosys-smtbmc >/dev/null || { echo "formal: yosys-smtbmc not found -- run 'make setup'"; exit 2; }
command -v "$SOLVER"   >/dev/null || { echo "formal: $SOLVER not found -- run 'make setup'"; exit 2; }

rm -rf "$WORK"; mkdir -p "$WORK"

# RELATIVE paths, from $ROOT, and this is not cosmetic. Yosys splits a
# -p script on whitespace, and this project lives in a directory whose
# name contains spaces:
#
#     ERROR: File `Lite' not found or is a directory
#
# The same trap docs/tooling_notes.md already records for Verilator's
# build directory, in a different tool. Quoting does not help -- the
# split happens inside the script parser -- so the fix is to give it
# paths with no spaces in them, which relative ones are.
echo "  yosys: reading rtl/axi4lite_reg_slave.sv with -DFORMAL"
cd "$ROOT" || exit 1
yosys -q -l "formal/build/yosys.log" -p "
    read_verilog -sv -formal -DFORMAL -I formal \
        rtl/gen/axi4lite_reg_pkg.sv rtl/axi4lite_reg_slave.sv;
    prep -top axi4lite_reg_slave -flatten;
    async2sync;
    dffunmap;
    write_smt2 -wires formal/build/reg_slave.smt2
" || { echo "formal: yosys failed -- see formal/build/yosys.log"; exit 1; }

FAILED=0

echo ""
echo "  === BMC, depth $DEPTH, solver $SOLVER ==="
yosys-smtbmc -s "$SOLVER" -t "$DEPTH" --dump-vcd "$WORK/bmc.vcd" \
    "$WORK/reg_slave.smt2" 2>&1 | tee "$WORK/bmc.log" | tail -6
grep -q "Status: PASSED" "$WORK/bmc.log" || FAILED=1

echo ""
echo "  === COVER, depth $DEPTH ==="
echo "  (a property nothing can reach passes trivially -- this is the check on that)"
yosys-smtbmc -s "$SOLVER" -t "$DEPTH" -c --dump-vcd "$WORK/cover.vcd" \
    "$WORK/reg_slave.smt2" 2>&1 | tee "$WORK/cover.log" | tail -12
grep -q "Status: PASSED" "$WORK/cover.log" || FAILED=1

echo ""
if [[ $FAILED -eq 0 ]]; then
    echo "  formal: PASSED -- no counter-example within $DEPTH cycles, and every"
    echo "          cover point reachable within $DEPTH cycles."
else
    echo "  formal: FAILED -- see $WORK/bmc.log and $WORK/cover.log"
    echo "          counter-example waveform: $WORK/bmc.vcd"
fi
exit $FAILED
