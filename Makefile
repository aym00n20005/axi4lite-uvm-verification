#=====================================================================
# AXI4-Lite peripheral subsystem — front door
#
#   make setup                one-time: slang, yosys, z3, UVM source
#   make elab                 elaborate the UVM testbench locally (slang)
#   make test                 all three smoke benches + assertions
#   make test TEST=reg        register slave only
#   make test TEST=mem        memory slave only
#   make test TEST=sys        interconnect + both slaves (DECERR lives here)
#   make test SIM=icarus      functional only; Icarus cannot do SVA
#   make regression           parallel multi-seed, results.json
#   make triage               what actually broke
#   make coverage             cover properties + functional, with a trend
#   make vplan                feature -> test -> result matrix
#   make import-log LOG=..    bring a UVM log in from EDA Playground
#   make formal               bounded model check (Yosys + z3)
#   make all                  everything that needs no person
#   make lint                 Verilator -Wall on the RTL
#   make playground PLAY=x    bundle UVM for EDA Playground
#                             proto | reg | ral | rand   <- the four that matter
#                             hello|rand_smoke|smoke|mem   (single-slave)
#   make clean
#
# Deliberately thin: it wraps the scripts rather than duplicating the
# flow. docs/automation_plan.md describes what each one is for.
#
# `make elab` is the important one and it is worth knowing why it is
# first. UVM cannot be simulated locally, so the only way to run this
# environment is to paste it into EDA Playground by hand — which makes a
# typo cost minutes rather than seconds. slang elaborates the generated
# bundle byte for byte in about a fifth of a second, so the browser is
# needed only for the thing a browser is actually needed for.
#=====================================================================

SIM  ?= verilator
TEST ?= all
JOBS ?= 8

# The register slave imports axi4lite_reg_pkg, so the two are one lint
# unit. The memory slave has no register map and stands alone.
REG_PKG  := rtl/gen/axi4lite_reg_pkg.sv
LINT_reg := $(REG_PKG) rtl/axi4lite_reg_slave.sv
LINT_mem := rtl/axi4lite_mem_slave.sv
LINT_ic  := rtl/axi4lite_interconnect.sv

.PHONY: test coverage cover-quick lint clean help playground setup elab \
        regmap regcheck regression triage vplan test-scripts import-log \
        formal onepager all docs

#---------------------------------------------------------------------
# One-time toolchain. Idempotent: brew and fetch_uvm.sh both no-op when
# what they install is already there, so this is safe to re-run.
#---------------------------------------------------------------------
setup:
	@command -v brew >/dev/null 2>&1 || { echo "setup: Homebrew required"; exit 1; }
	@echo "  brew  svlang yosys z3"
	@brew list svlang >/dev/null 2>&1 || brew install svlang
	@brew list yosys  >/dev/null 2>&1 || brew install yosys
	@brew list z3     >/dev/null 2>&1 || brew install z3
	@echo "  pip   pyyaml jinja2"
	@python3 -m pip install --quiet pyyaml jinja2
	@./scripts/fetch_uvm.sh
	@echo "setup: done"

# Elaboration, not simulation. See the header, and scripts/elab.sh.
elab:
	@./scripts/elab.sh $(PLAY)

test:
	@./scripts/run_sim.sh $(SIM) $(TEST)

#---------------------------------------------------------------------
# The flow. docs/automation_plan.md T1-T6.
#---------------------------------------------------------------------

# T1. Parallel, multi-seed, exit code. Local runs are launched; UVM runs
# are imported from sim/logs/ because no local simulator runs UVM.
regression:
	@python3 scripts/run_regression.py --jobs $(JOBS)

# T3. What actually broke: clusters, new-since-last-run, flaky, stale.
triage:
	@python3 scripts/triage.py $(TRIAGE_ARGS)

# T5. Cover properties from Verilator + the UVM hand tally, with a trend.
coverage:
	@python3 scripts/coverage_report.py

# The old behaviour, when you just want the counts on one bench.
cover-quick:
	@./scripts/run_sim.sh verilator $(TEST) --coverage

# T6. feature -> test -> result. The one that answers "are we done".
vplan:
	@python3 scripts/vplan_trace.py

# Bounded model check. The only flow that can decide spec section 5's
# same-cycle rules -- see docs/formal_notes.md.
DEPTH ?= 25
formal:
	@./formal/run_formal.sh $(DEPTH)

# T2's test suite. The parser everything else is built on.
test-scripts:
	@python3 scripts/test_parse_log.py

#---------------------------------------------------------------------
# Bring a UVM log in from EDA Playground.
#
#   make import-log LOG=~/Downloads/sys.log TEST=axi_regression_test
#
# This is the ONE manual step in the flow and the Makefile says so
# rather than hiding it. UVM cannot be simulated locally -- Icarus and
# Verilator have no UVM support -- so somebody has to paste two panes
# into a browser. Everything before that point is `make elab`;
# everything after it is automated.
#---------------------------------------------------------------------
LOG  ?=
TEST_NAME ?= $(TEST)

import-log:
	@if [ -z "$(LOG)" ]; then 	  echo "usage: make import-log LOG=<file> TEST=<axi_protocol_test|axi_register_test|axi_ral_test|axi_multiseed_test>"; exit 2; fi
	@if [ ! -f "$(LOG)" ]; then echo "import-log: no such file: $(LOG)"; exit 2; fi
	@mkdir -p sim/logs
	@case "$(TEST)" in 	  axi_regression_test) dest=sim/logs/sys.log  ;; 	  axi_ral_test)        dest=sim/logs/ral.log  ;; 	  axi_multiseed_test)  dest=sim/logs/rand.log ;; 	  *) echo "import-log: TEST must be axi_regression_test, axi_ral_test or axi_multiseed_test"; exit 2 ;; 	esac; 	cp "$(LOG)" "$$dest"; 	echo "  imported $(LOG) -> $$dest"; 	python3 scripts/parse_log.py "$$dest"

#---------------------------------------------------------------------
# Everything that can run without a person, in dependency order.
#---------------------------------------------------------------------
all: regcheck elab lint test-scripts regression triage coverage vplan formal
	@echo ""
	@echo "  all: done. docs/traceability.md is the one to read."

# The printable brief. Committed, unlike every other generated file --
# it is the one document that gets read away from the repository, where
# nobody can check its figures against a run.
onepager:
	@./scripts/make_onepager.sh

# Regenerate every generated document from what has been measured.
docs: regmap coverage vplan onepager
	@echo "docs: register_map.md, coverage_report.md, traceability.md, one_pager.pdf"

# One slave at a time: linting both together trips MULTITOP, since each
# is a legitimate top in its own right.
lint:
	@echo "  lint axi4lite_reg_slave (+ generated package)"
	@verilator --lint-only -Wall --timing $(LINT_reg)
	@echo "  lint axi4lite_mem_slave"
	@verilator --lint-only -Wall --timing $(LINT_mem)
	@echo "  lint axi4lite_interconnect"
	@verilator --lint-only -Wall --timing $(LINT_ic)
	@echo "lint: clean"

#---------------------------------------------------------------------
# Register map. regmap.yaml -> RTL package + RAL model + documentation.
# regcheck closes the one edge generation cannot: YAML vs the spec.
#---------------------------------------------------------------------
regmap:
	@python3 scripts/regmap_gen.py
	@python3 scripts/check_regmap.py

regcheck:
	@python3 scripts/check_regmap.py
	@python3 scripts/regmap_gen.py --check

#---------------------------------------------------------------------
# EDA Playground bundling.
#
# Playground has two panes and no file list, so multi-file UVM source has
# to arrive as one paste. This concatenates a named bundle in dependency
# order and emits the uvm_macros include / uvm_pkg import exactly once.
#
# The guard tests for '^import uvm_pkg', not for the word uvm_macros.svh:
# source comments mention that filename, so a looser grep matches a comment
# and silently skips the preamble the bundle actually needs.
#
# UVM cannot be run locally -- neither Icarus nor Verilator supports it --
# so this target only produces the file. Running it is manual, on
# EDA Playground with Cadence Xcelium. See docs/tooling_notes.md.
#---------------------------------------------------------------------
PLAY ?= rand_smoke

# Playground's command line is fixed, so the seed travels as a define
# written into the generated bundle: `make playground PLAY=rand SEED=7`.
SEED ?= 1

# EDA Playground refuses a pane larger than this. Comments are stripped
# from the generated bundle to fit -- they stay in the repository, since
# the paste is a transient artifact for one tool. See
# scripts/strip_comments.py, and the four-bundle split below.
PANE_LIMIT ?= 100000

PLAY_rand_smoke := tb/agent/axi_transaction.sv tb/agent/axi_sequencer.sv tb/uvm/axi_rand_smoke.sv
PLAY_hello      := tb/uvm/uvm_hello.sv

# The first bundle that needs a DESIGN pane: the driver drives real pins,
# so the interface, the DUT and the bound checker have to be there too.
# Only the register slave and only its bind. Adding the memory slave to
# satisfy a combined bind file elaborated it as a second, unconnected
# top-level module with floating inputs and a checker bound to it --
# harmless here only because ARESETn was X, which is not a guarantee.
PLAY_smoke_DESIGN := tb/interface/axi4lite_if.sv $(REG_PKG) rtl/axi4lite_reg_slave.sv \
                     tb/interface/axi4lite_reg_bind.sv
PLAY_smoke        := tb/agent/axi_transaction.sv tb/agent/axi_sequencer.sv \
                     tb/agent/axi_driver.sv tb/agent/axi_monitor.sv \
                     tb/agent/axi_master_agent.sv \
                     tb/sequences/axi_base_seq.sv tb/sequences/axi_smoke_seq.sv \
                     tb/sequences/axi_seqs.sv \
                     tb/env/axi_scoreboard.sv tb/env/axi_coverage.sv tb/env/axi_env.sv \
                     tb/tests/axi_base_test.sv tb/tests/axi_smoke_test.sv \
                     tb/tests/axi_random_test.sv \
                     tb/tests/axi_watchdog.sv tb/tests/tb_top.sv

# The memory slave's own top. A separate DUT and a separate bind, because
# there is no interconnect: each top has exactly one slave.
PLAY_mem_DESIGN := tb/interface/axi4lite_if.sv rtl/axi4lite_mem_slave.sv \
                   tb/interface/axi4lite_mem_bind.sv
PLAY_mem        := tb/agent/axi_transaction.sv tb/agent/axi_sequencer.sv \
                   tb/agent/axi_driver.sv tb/agent/axi_monitor.sv \
                   tb/agent/axi_master_agent.sv \
                   tb/sequences/axi_base_seq.sv tb/sequences/axi_smoke_seq.sv \
                   tb/sequences/axi_seqs.sv \
                   tb/env/axi_scoreboard.sv tb/env/axi_coverage.sv tb/env/axi_env.sv \
                   tb/tests/axi_base_test.sv tb/tests/axi_smoke_test.sv \
                   tb/tests/axi_mem_test.sv \
                   tb/tests/axi_watchdog.sv tb/tests/tb_top_mem.sv

# Identical sources; the bundle differs only in which test AXI_TEST names.
# Must come AFTER PLAY_smoke: ':=' expands immediately, so referencing it
# earlier would silently produce an empty file list.
PLAY_random_DESIGN := $(PLAY_smoke_DESIGN)
PLAY_random        := $(PLAY_smoke)
PLAY_random_TEST := axi_random_test

#---------------------------------------------------------------------
# The system bundles -- the ones that actually get pasted.
#
# tb_top_sys holds the interconnect and both slaves, so one bundle can
# host many tests rather than one bundle per slave per test.
#
# FOUR BUNDLES, NOT ONE, AND NOT THREE.
#
# EDA Playground caps each pane at 100,000 characters. The whole
# environment plus all thirteen directed scenarios is 133,000 even with
# every comment stripped, so it does not fit however it is arranged --
# this is a tool limit, not a packaging choice.
#
# The split is therefore by what the tests are ABOUT, so that it means
# something rather than being an arbitrary cut at 100 KB:
#
#   proto   protocol and decode -- reset, ordering, byte enables,
#           alignment, routing, backpressure, back-to-back, memory
#   reg     register semantics -- strobe rule, error precedence,
#           INT_STATUS, STATUS, COUNTER
#   ral     the generated register model: hw_reset + bit_bash + policy
#   rand    eight seeds of constrained-random traffic
#
# Sixteen tests and eight seeds still cost four pastes rather than
# twenty-four, and `make elab` means none of the four is ever spent on
# a typo.
#
# All four share a DESIGN pane.
#---------------------------------------------------------------------
PLAY_SYS_DESIGN := tb/interface/axi4lite_if.sv $(REG_PKG) \
                   rtl/axi4lite_reg_slave.sv rtl/axi4lite_mem_slave.sv \
                   rtl/axi4lite_interconnect.sv \
                   tb/interface/axi4lite_reg_bind.sv \
                   tb/interface/axi4lite_mem_bind.sv \
                   tb/interface/axi4lite_sys_bind.sv

# Everything every bundle needs. The RAL is NOT here -- it is 8,700
# characters and only one bundle has a register model in it.
PLAY_CORE := tb/agent/axi_transaction.sv tb/agent/axi_sequencer.sv \
             tb/agent/axi_driver.sv tb/agent/axi_monitor.sv \
             tb/agent/axi_master_agent.sv \
             tb/sequences/axi_base_seq.sv \
             tb/env/axi_scoreboard.sv tb/env/axi_coverage.sv tb/env/axi_env.sv \
             tb/tests/axi_base_test.sv

PLAY_TOP := tb/tests/axi_watchdog.sv tb/tests/tb_top_sys.sv

PLAY_proto_DESIGN := $(PLAY_SYS_DESIGN)
PLAY_proto        := $(PLAY_CORE) tb/sequences/axi_smoke_seq.sv \
                     tb/sequences/axi_proto_seqs.sv \
                     tb/tests/axi_smoke_test.sv \
                     tb/tests/axi_proto_tests.sv $(PLAY_TOP)
PLAY_proto_TEST := axi_protocol_test

PLAY_reg_DESIGN := $(PLAY_SYS_DESIGN)
PLAY_reg        := $(PLAY_CORE) tb/sequences/axi_reg_seqs.sv \
                   tb/tests/axi_reg_tests.sv $(PLAY_TOP)
PLAY_reg_TEST := axi_register_test

PLAY_ral_DESIGN := $(PLAY_SYS_DESIGN)
PLAY_ral        := tb/agent/axi_transaction.sv tb/agent/axi_sequencer.sv \
                   tb/agent/axi_driver.sv tb/agent/axi_monitor.sv \
                   tb/agent/axi_master_agent.sv \
                   tb/ral/axi_reg_block.sv tb/ral/axi_reg_adapter.sv \
                   tb/sequences/axi_base_seq.sv tb/sequences/axi_ral_seq.sv \
                   tb/env/axi_scoreboard.sv tb/env/axi_coverage.sv tb/env/axi_env.sv \
                   tb/tests/axi_base_test.sv tb/tests/axi_ral_test.sv $(PLAY_TOP)
PLAY_ral_TEST  := axi_ral_test
PLAY_ral_EXTRA := `define AXI_RAL

PLAY_rand_DESIGN := $(PLAY_SYS_DESIGN)
PLAY_rand        := $(PLAY_CORE) tb/sequences/axi_seqs.sv \
                    tb/tests/axi_random_test.sv tb/tests/axi_mem_test.sv \
                    tb/tests/axi_rand_tests.sv $(PLAY_TOP)
PLAY_rand_TEST := axi_multiseed_test

PLAY_proto_NOTE := yes
PLAY_reg_NOTE   := yes
PLAY_ral_NOTE   := yes
PLAY_rand_NOTE  := yes

playground:
	@mkdir -p sim
	@srcs="$(PLAY_$(PLAY))"; \
	 if [ -z "$$srcs" ]; then \
	   echo "unknown bundle '$(PLAY)' -- try hello, rand_smoke, smoke, random or mem"; exit 2; fi; \
	 out=sim/playground_$(PLAY).sv; \
	 { echo "// GENERATED by 'make playground PLAY=$(PLAY)' -- do not edit."; \
	   echo "// Paste into the EDA Playground TESTBENCH pane."; \
	   if [ -n "$(PLAY_$(PLAY)_DESIGN)" ]; then \
	     echo "// The DESIGN pane takes sim/playground_$(PLAY)_design.sv."; \
	   else echo "// Leave the DESIGN pane empty."; fi; \
	   echo "// Simulator: Cadence Xcelium.  UVM: 1.2.  (Riviera compiles but cannot simulate.)"; \
	   echo "// Sources, in order:"; \
	   for f in $$srcs; do echo "//   $$f"; done; \
	   echo ""; \
	   if ! grep -q '^import uvm_pkg' $$srcs; then \
	     echo '`include "uvm_macros.svh"'; echo "import uvm_pkg::*;"; echo ""; fi; \
	   if [ -n '$(PLAY_$(PLAY)_NOTE)' ]; then \
	     echo "//===================================================================="; \
	     echo "//  FOUR RUNS, ONE DESIGN PANE."; \
	     echo "//"; \
	     echo "//  All four bundles share this DESIGN pane. Paste the design"; \
	     echo "//  once and leave it; only the TESTBENCH pane changes between"; \
	     echo "//  runs:"; \
	     echo "//"; \
	     echo "//      make playground PLAY=proto   protocol and decode"; \
	     echo "//      make playground PLAY=reg     register semantics"; \
	     echo "//      make playground PLAY=ral     the generated register model"; \
	     echo "//      make playground PLAY=rand    8 seeds of random traffic"; \
	     echo "//"; \
	     echo "//  Four rather than one because EDA Playground caps a pane at"; \
	     echo "//  100,000 characters and the environment plus all thirteen"; \
	     echo "//  scenarios is 133,000 with every comment already stripped."; \
	     echo "//"; \
	     echo "//  AXI_SEED changes the randomisation. Playground's command line is"; \
	     echo "//  fixed -- no +SVSEED -- so a define is the only way in, and without"; \
	     echo "//  it Xcelium reports 'SVSEED default: 1' and every run is identical."; \
	     echo "//"; \
	     echo "//  Save each log, then:  make import-log LOG=<file> TEST=<name>"; \
	     echo "//===================================================================="; \
	     echo ""; fi; \
	   if [ -n '$(PLAY_$(PLAY)_EXTRA)' ]; then echo '$(PLAY_$(PLAY)_EXTRA)'; fi; \
	   if [ -n '$(PLAY_$(PLAY)_TEST)' ]; then echo '`define AXI_TEST "$(PLAY_$(PLAY)_TEST)"'; fi; \
	   echo '`define AXI_SEED $(SEED)'; echo ""; \
	   for f in $$srcs; do \
	     echo "//================ $$f ================"; cat $$f; echo ""; done; \
	 } > $$out; \
	 wrote_tb="$$out"; \
	 if LC_ALL=C grep -qn '[^ -~\t]' $$out; then \
	   echo "ERROR: non-ASCII in $$out -- Xcelium drops those bytes from string"; \
	   echo "       literals (*W,NONPRT) and mangles the log. Offending lines:"; \
	   LC_ALL=C grep -n '[^ -~\t]' $$out | head -5; exit 1; fi; \
	 wrote_design=""; \
	 dsrcs="$(PLAY_$(PLAY)_DESIGN)"; \
	 if [ -n "$$dsrcs" ]; then \
	   dout=sim/playground_$(PLAY)_design.sv; \
	   { echo "// GENERATED by 'make playground PLAY=$(PLAY)' -- do not edit."; \
	     echo "// Paste into the EDA Playground DESIGN pane."; \
	     for f in $$dsrcs; do echo "//   $$f"; done; echo ""; \
	     for f in $$dsrcs; do \
	       echo "//================ $$f ================"; cat $$f; echo ""; done; \
	   } > $$dout; \
	   wrote_design="$$dout"; \
	 fi; \
	 python3 scripts/strip_comments.py $$wrote_tb $$wrote_tb.tmp >/dev/null && mv $$wrote_tb.tmp $$wrote_tb; \
	 if [ -n "$$wrote_design" ]; then \
	   python3 scripts/strip_comments.py $$wrote_design $$wrote_design.tmp >/dev/null && mv $$wrote_design.tmp $$wrote_design; \
	 fi; \
	 want='$(PLAY_$(PLAY)_TEST)'; \
	 if [ -n "$$want" ] && ! grep -q "\`define AXI_TEST \"$$want\"" $$wrote_tb; then \
	   echo "ERROR: $$wrote_tb does not define AXI_TEST as \"$$want\"."; \
	   echo "       Without it tb_top_sys falls back to its default and the run"; \
	   echo "       dies at time 0 with UVM_FATAL [INVTST]."; exit 1; fi; \
	 over=0; \
	 for f in $$wrote_design $$wrote_tb; do \
	   n=$$(wc -c < $$f | tr -d ' '); \
	   if [ "$$n" -ge $(PANE_LIMIT) ]; then \
	     echo "ERROR: $$f is $$n characters; EDA Playground's limit is $(PANE_LIMIT)."; \
	     echo "       Move files between bundles in the Makefile, or add one."; \
	     over=1; fi; \
	 done; \
	 [ $$over -eq 0 ] || exit 1; \
	 echo ""; \
	 echo "  ================ PASTE INTO EDA PLAYGROUND ================"; \
	 if [ -n "$$wrote_design" ]; then \
	   echo "    DESIGN pane     <-  $$wrote_design  ($$(wc -c < $$wrote_design | tr -d ' ') chars, limit $(PANE_LIMIT))"; \
	 else \
	   echo "    DESIGN pane     <-  (leave empty)"; \
	 fi; \
	 echo "    TESTBENCH pane  <-  $$wrote_tb  ($$(wc -c < $$wrote_tb | tr -d ' ') chars, limit $(PANE_LIMIT))"; \
	 echo ""; \
	 echo "    Simulator: Cadence Xcelium     UVM: 1.2"; \
	 echo "    Clear both panes first -- stale content is silently compiled."; \
	 echo "  ==========================================================="; \
	 echo ""

clean:
	@rm -rf sim/*.out sim/*.vcd sim/*.dat sim/cov_annotated sim/playground_*.sv
	@rm -rf $${TMPDIR:-/tmp}/axi4lite_vbuild
	@echo "clean: done"

# Print the header block, however long it happens to be, instead of a
# fixed line range that silently truncates every time a target is added.
help:
	@sed -n '/^#   make setup/,/^#   make clean/p' Makefile | sed 's/^# \?//'
