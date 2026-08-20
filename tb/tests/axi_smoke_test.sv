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

    task run_phase(uvm_phase phase);
        axi_smoke_seq seq;
        phase.raise_objection(this, "smoke sequence");
        seq = axi_smoke_seq::type_id::create("seq");
        seq.start(env.agent.sqr);
        #200ns;                     // let the last response drain
        phase.drop_objection(this, "smoke sequence done");
    endtask

endclass : axi_smoke_test
