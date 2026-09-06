//======================================================================
// axi_mem_test.sv
//
// The memory slave's first contact with the UVM environment.
//
// Everything below the test is reused unchanged: the same agent, the
// same driver, the same pin-only monitor, the same coverage collector.
// Only the scoreboard is told which slave it is modelling, and only
// because there is no interconnect yet to decide it by address.
//
// Reuse is the claim the verification plan makes about this agent
// ("configurable active or passive, so it can be reused to observe a
// second port later"). This is the first thing that tests the claim.
//======================================================================

class axi_mem_test extends axi_base_test;

    `uvm_component_utils(axi_mem_test)

    axi_mem_seq seq;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this, "memory sequence");
        seq = axi_mem_seq::type_id::create("seq");
        seq.seed = base_seed;
        seq.start(env.agent.sqr);
        note(seq);
        #200ns;
        phase.drop_objection(this, "memory sequence done");
    endtask

endclass : axi_mem_test
