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

    //------------------------------------------------------------------
    // The RAL, and the predictor that keeps its mirror honest.
    //
    // Built only when a test asks for it. Most tests do not need a
    // register model, and a locked reg block on a test that drives raw
    // addresses is one more thing whose mirror can be wrong without
    // anyone looking. axi_ral_test sets "use_ral".
    //------------------------------------------------------------------
    // Guarded by `AXI_RAL, which only the RAL bundle defines.
    //
    // Not an optimisation for its own sake: EDA Playground caps a pane
    // at 100,000 characters, and the RAL model and adapter are 8,700 of
    // them. Three of the four bundles have no register model in them at
    // all, so declaring handles of types they do not include would not
    // elaborate.
`ifdef AXI_RAL
    axi_reg_block                        regmodel;
    axi_reg_adapter                      adapter;
    uvm_reg_predictor #(axi_transaction) predictor;
`endif
    bit                                  use_ral = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent = axi_master_agent::type_id::create("agent", this);
        sb    = axi_scoreboard  ::type_id::create("sb", this);
        cov   = axi_coverage    ::type_id::create("cov", this);

        void'(uvm_config_db #(bit)::get(this, "", "use_ral", use_ral));
`ifdef AXI_RAL
        if (use_ral) begin
            regmodel = axi_reg_block::type_id::create("regmodel");
            regmodel.build();
            regmodel.lock_model();
            adapter   = axi_reg_adapter::type_id::create("adapter");
            predictor = uvm_reg_predictor #(axi_transaction)::type_id::create("predictor", this);
        end
`else
        if (use_ral)
            `uvm_fatal(get_type_name(),
                "use_ral is set but this build has no register model -- the bundle must define AXI_RAL")
`endif
    endfunction

    // Bottom-up: the agent and its monitor already exist.
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        agent.mon.ap.connect(sb.analysis_export);
        agent.mon.ap.connect(cov.analysis_export);
        // Second port: reset events, for cg_reset. Not a transaction, so
        // not on ap -- see axi_monitor.sv's reset_watch.
        agent.mon.rst_ap.connect(cov.rst_export);
        // The scoreboard needs it too: without this its register model
        // survives a reset the DUT did not. BUG-011.
        agent.mon.rst_ap.connect(sb.rst_export);

`ifdef AXI_RAL
        if (use_ral) begin
            // Frontdoor: RAL sequences go through the same sequencer,
            // driver and pins as everything else. No backdoor is
            // configured -- a backdoor write proves nothing about the
            // bus, and the bus is what is being verified.
            regmodel.axi_map.set_sequencer(agent.sqr, adapter);

            // EXPLICIT prediction. The mirror is updated from the
            // MONITOR, not from the operation the sequence issued -- see
            // axi_reg_adapter.sv. Turning auto-predict off is what makes
            // the predictor the only writer; leaving both on would give
            // the mirror two sources and a double update on every access.
            regmodel.axi_map.set_auto_predict(0);
            predictor.map     = regmodel.axi_map;
            predictor.adapter = adapter;
            agent.mon.ap.connect(predictor.bus_in);
        end
`endif
    endfunction

endclass : axi_env
