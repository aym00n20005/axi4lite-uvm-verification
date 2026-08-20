//======================================================================
// axi_env.sv
//
// Scoreboard and coverage collector join on 26-27 Aug. The env exists
// now so that everything added later slots into a hierarchy the tests
// already refer to.
//======================================================================

class axi_env extends uvm_env;

    `uvm_component_utils(axi_env)

    axi_master_agent agent;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent = axi_master_agent::type_id::create("agent", this);
    endfunction

endclass : axi_env
