#=====================================================================
# AXI4-Lite peripheral subsystem — front door
#
#   make test                 both smoke benches, Verilator + assertions
#   make test TEST=reg        register slave only
#   make test TEST=mem        memory slave only
#   make test SIM=icarus      functional only; Icarus cannot do SVA
#   make coverage             cover-property counts for both benches
#   make lint                 Verilator -Wall on the RTL
#   make clean
#
# Deliberately thin: it wraps scripts/run_sim.sh rather than duplicating
# the flow. Per docs/automation_plan.md, the toolkit proper (regression
# runner, log parser) is a September build; before DVCon this file is the
# only automation, and its job is to make `make test` the thing you type.
#
# September's targets — `make regression`, `make test TEST=axi_smoke_test
# SEED=42` — hang off this same front door once run_regression.py exists.
#=====================================================================

SIM  ?= verilator
TEST ?= all
RTL  := rtl/axi4lite_reg_slave.sv rtl/axi4lite_mem_slave.sv

.PHONY: test coverage lint clean help

test:
	@./scripts/run_sim.sh $(SIM) $(TEST)

coverage:
	@./scripts/run_sim.sh verilator $(TEST) --coverage

# One file at a time: linting both together trips MULTITOP, since each
# is a legitimate top in its own right until the interconnect exists.
lint:
	@for f in $(RTL); do \
		echo "  lint $$f"; \
		verilator --lint-only -Wall --timing $$f || exit 1; \
	done
	@echo "lint: clean"

clean:
	@rm -rf sim/*.out sim/*.vcd sim/*.dat sim/cov_annotated
	@rm -rf $${TMPDIR:-/tmp}/axi4lite_vbuild
	@echo "clean: done"

help:
	@sed -n '4,10p' Makefile | sed 's/^# \?//'
