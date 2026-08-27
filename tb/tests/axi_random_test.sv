//======================================================================
// axi_random_test.sv
//
// Verification plan test list: axi_random_test, "constrained-random
// mixed traffic", features F01, F02, F14, F28.
//
// The scoreboard has never disagreed with the DUT. That is not yet
// evidence of anything: it has only ever been shown 44 transactions a
// human picked. This is the first test where nobody chose the addresses.
//======================================================================

class axi_random_test extends axi_base_test;

    `uvm_component_utils(axi_random_test)

    axi_random_seq seq;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this, "random traffic");
        seq = axi_random_seq::type_id::create("seq");
        seq.start(env.agent.sqr);
        #500ns;                     // let the last responses drain
        phase.drop_objection(this, "random traffic done");
    endtask

    //------------------------------------------------------------------
    // Same three-way independence check as the smoke test: the sequence
    // counts what it issued, the monitor counts pin handshakes with no
    // access to the driver, the scoreboard counts analysis-port arrivals.
    //
    // It matters more here. Under back-to-back traffic the monitor's
    // accept queues are exercised for the first time in the case they
    // were built for -- a response completing on the same cycle as a new
    // accept. A dropped or double-counted transaction shows up here.
    //------------------------------------------------------------------
    function void check_phase(uvm_phase phase);
        axi_monitor mon = env.agent.mon;
        super.check_phase(phase);

        `uvm_info(get_type_name(),
            $sformatf("issued %0d writes / %0d reads | monitor saw %0d / %0d | scoreboard got %0d / %0d",
                      seq.issued_writes, seq.issued_reads,
                      mon.n_writes, mon.n_reads,
                      env.sb.n_writes, env.sb.n_reads), UVM_LOW)

        if (mon.n_writes != seq.issued_writes)
            `uvm_error(get_type_name(),
                $sformatf("monitor saw %0d writes, sequence issued %0d",
                          mon.n_writes, seq.issued_writes))
        if (mon.n_reads != seq.issued_reads)
            `uvm_error(get_type_name(),
                $sformatf("monitor saw %0d reads, sequence issued %0d",
                          mon.n_reads, seq.issued_reads))
        if (env.sb.n_writes != mon.n_writes || env.sb.n_reads != mon.n_reads)
            `uvm_error(get_type_name(), "analysis port dropped transactions");
    endfunction

endclass : axi_random_test
