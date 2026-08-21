//======================================================================
// axi_env.sv
//
// Scoreboard and coverage collector both hang off mon.ap. Both are fed by
// observation, never by stimulus -- a coverage model driven from the
// sequence measures the testbench's intentions rather than the DUT's
// experience.
//======================================================================

class axi_env extends uvm_env;

    `uvm_component_utils(axi_env)

    axi_master_agent agent;
    axi_scoreboard   sb;
    axi_coverage     cov;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent = axi_master_agent::type_id::create("agent", this);
        sb    = axi_scoreboard  ::type_id::create("sb", this);
        cov   = axi_coverage    ::type_id::create("cov", this);
    endfunction

    // Bottom-up: the agent and its monitor already exist.
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        agent.mon.ap.connect(sb.analysis_export);
        agent.mon.ap.connect(cov.analysis_export);
    endfunction

endclass : axi_env
