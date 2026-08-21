//======================================================================
// axi_env.sv
//
// The coverage collector joins on 27 Aug, on the same mon.ap.
// axi_observer is gone: it counted, and the scoreboard counts as well as
// checking.
//======================================================================

class axi_env extends uvm_env;

    `uvm_component_utils(axi_env)

    axi_master_agent agent;
    axi_scoreboard   sb;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent = axi_master_agent::type_id::create("agent", this);
        sb    = axi_scoreboard  ::type_id::create("sb", this);
    endfunction

    // Bottom-up: the agent and its monitor already exist.
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        agent.mon.ap.connect(sb.analysis_export);
    endfunction

endclass : axi_env
