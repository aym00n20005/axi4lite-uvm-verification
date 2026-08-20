//======================================================================
// axi_env.sv
//
// The scoreboard replaces axi_observer on 26 Aug; the coverage collector
// joins on 27 Aug. Both hang off the same mon.ap.
//======================================================================

class axi_env extends uvm_env;

    `uvm_component_utils(axi_env)

    axi_master_agent agent;
    axi_observer     obs;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent = axi_master_agent::type_id::create("agent", this);
        obs   = axi_observer    ::type_id::create("obs", this);
    endfunction

    // Bottom-up: the agent and its monitor already exist.
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        agent.mon.ap.connect(obs.analysis_export);
    endfunction

endclass : axi_env
