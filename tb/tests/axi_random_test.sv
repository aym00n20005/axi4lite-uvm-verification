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
        seq.seed = base_seed;
        seq.start(env.agent.sqr);
        note(seq);
        #500ns;                     // let the last responses drain
        phase.drop_objection(this, "random traffic done");
    endtask

    // The three-way independence check lives in axi_base_test, once, and
    // it matters more here than anywhere: under back-to-back traffic the
    // monitor's accept queues are exercised in the case they were built
    // for -- a response completing on the same cycle as a new accept. A
    // dropped or double-counted transaction shows up there.

endclass : axi_random_test
