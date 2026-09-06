//======================================================================
// axi_smoke_test.sv
//
// The first UVM test that touches pins. Mirrors sanity_tb.sv so that a
// failure can be compared against a bench known to pass on the same RTL.
//======================================================================

class axi_base_test extends uvm_test;

    `uvm_component_utils(axi_base_test)

    axi_env env;

    // Seed for every sequence this test starts. From the config_db,
    // which tb_top* fills from the AXI_SEED define -- Playground's
    // command line is fixed, so a define is the only route in.
    int unsigned base_seed = 1;

    // Running totals across every sequence the test ran. A test with one
    // sequence and a test with fourteen check the same way.
    int unsigned tally_writes = 0;
    int unsigned tally_reads  = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        // Set before the child builds -- legal because build is top-down.
        uvm_config_db #(uvm_active_passive_enum)::set(this, "env.agent", "is_active", UVM_ACTIVE);
        if (!uvm_config_db #(int unsigned)::get(this, "", "axi_seed", base_seed))
            base_seed = 1;
        env = axi_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        uvm_top.print_topology();
        `uvm_info(get_type_name(), $sformatf("base seed %0d", base_seed), UVM_LOW)
    endfunction

    // Every test calls this after each sequence it runs, so the
    // end-of-test count check below works for one sequence or fourteen.
    function void note(axi_base_seq s);
        tally_writes += s.issued_writes;
        tally_reads  += s.issued_reads;
    endfunction

    //------------------------------------------------------------------
    // The monitor-independence check, once, for every test.
    //
    // The sequence counts what it ISSUED. The monitor counts what it SAW
    // on the pins, with no handle to the driver and no access to any of
    // its state. The scoreboard counts what arrived on the analysis
    // port. Three numbers derived along paths that share nothing, and
    // they must agree.
    //
    // If the monitor were echoing the driver rather than reconstructing
    // from pins, these would agree trivially and prove nothing -- which
    // is exactly why the monitor has no way to reach the driver at all.
    //
    // The one legitimate difference is a transaction reset took away
    // before the bus could answer it: spec section 3 rule 7 holds every
    // VALID low in reset, so no B or R can arrive and the monitor
    // correctly never sees it. The driver counts those, and they are
    // SUBTRACTED rather than tolerated -- a check with slack in it is a
    // check that stops detecting the thing it was written for.
    //------------------------------------------------------------------
    function void check_phase(uvm_phase phase);
        axi_monitor mon = env.agent.mon;
        int unsigned exp_w, exp_r;
        super.check_phase(phase);

        exp_w = tally_writes - env.agent.drv.aborted_writes;
        exp_r = tally_reads  - env.agent.drv.aborted_reads;

        `uvm_info(get_type_name(),
            $sformatf("issued %0d writes / %0d reads (%0d / %0d abandoned by reset) | monitor saw %0d / %0d | scoreboard got %0d / %0d",
                      tally_writes, tally_reads,
                      env.agent.drv.aborted_writes, env.agent.drv.aborted_reads,
                      mon.n_writes, mon.n_reads,
                      env.sb.n_writes, env.sb.n_reads), UVM_LOW)

        if (mon.n_writes != exp_w)
            `uvm_error(get_type_name(),
                $sformatf("monitor saw %0d writes, sequence issued %0d with %0d abandoned",
                          mon.n_writes, tally_writes, env.agent.drv.aborted_writes))
        if (mon.n_reads != exp_r)
            `uvm_error(get_type_name(),
                $sformatf("monitor saw %0d reads, sequence issued %0d with %0d abandoned",
                          mon.n_reads, tally_reads, env.agent.drv.aborted_reads))
        if (env.sb.n_writes != mon.n_writes || env.sb.n_reads != mon.n_reads)
            `uvm_error(get_type_name(), "analysis port dropped transactions")
        if (tally_writes == 0 && tally_reads == 0)
            `uvm_error(get_type_name(), "this test issued nothing at all")
    endfunction

endclass


class axi_smoke_test extends axi_base_test;

    `uvm_component_utils(axi_smoke_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    axi_smoke_seq seq;

    task run_phase(uvm_phase phase);
        phase.raise_objection(this, "smoke sequence");
        seq = axi_smoke_seq::type_id::create("seq");
        seq.seed = base_seed;
        seq.start(env.agent.sqr);
        note(seq);
        #200ns;                     // let the last response drain
        phase.drop_objection(this, "smoke sequence done");
    endtask

endclass : axi_smoke_test
