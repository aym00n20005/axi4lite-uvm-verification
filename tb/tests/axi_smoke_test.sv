//======================================================================
// axi_smoke_test.sv
//
// The first UVM test that touches pins. Mirrors sanity_tb.sv so that a
// failure can be compared against a bench known to pass on the same RTL.
//======================================================================

class axi_base_test extends uvm_test;

    `uvm_component_utils(axi_base_test)

    axi_env env;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        // Set before the child builds -- legal because build is top-down.
        uvm_config_db #(uvm_active_passive_enum)::set(this, "env.agent", "is_active", UVM_ACTIVE);
        env = axi_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        uvm_top.print_topology();
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
        seq.start(env.agent.sqr);
        #200ns;                     // let the last response drain
        phase.drop_objection(this, "smoke sequence done");
    endtask

    //------------------------------------------------------------------
    // The monitor-independence check.
    //
    // The sequence counts what it ISSUED. The monitor counts what it SAW
    // on the pins, with no handle to the driver and no access to any of
    // its state. The observer counts what arrived on the analysis port.
    // Three numbers derived along paths that share nothing, and they must
    // agree.
    //
    // If the monitor were echoing the driver rather than reconstructing
    // from pins, these would agree trivially and prove nothing -- which is
    // exactly why the monitor has no way to reach the driver at all.
    //------------------------------------------------------------------
    function void check_phase(uvm_phase phase);
        axi_monitor mon = env.agent.mon;
        super.check_phase(phase);

        `uvm_info(get_type_name(),
            $sformatf("issued %0d writes / %0d reads | monitor saw %0d / %0d | observer got %0d / %0d",
                      seq.issued_writes, seq.issued_reads,
                      mon.n_writes, mon.n_reads,
                      env.obs.n_writes, env.obs.n_reads), UVM_LOW)

        if (mon.n_writes != seq.issued_writes)
            `uvm_error(get_type_name(),
                $sformatf("monitor saw %0d writes, sequence issued %0d",
                          mon.n_writes, seq.issued_writes))
        if (mon.n_reads != seq.issued_reads)
            `uvm_error(get_type_name(),
                $sformatf("monitor saw %0d reads, sequence issued %0d",
                          mon.n_reads, seq.issued_reads))

        if (env.obs.n_writes != mon.n_writes || env.obs.n_reads != mon.n_reads)
            `uvm_error(get_type_name(), "analysis port dropped transactions")
    endfunction

endclass : axi_smoke_test
