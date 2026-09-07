//======================================================================
// axi_smoke_test.sv
//
// The first UVM test that touches pins. Mirrors sanity_tb.sv so that a
// failure can be compared against a bench known to pass on the same RTL.
//
// NOT independently compilable -- see tb/agent/axi_transaction.sv.
//======================================================================

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
