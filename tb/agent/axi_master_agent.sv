//======================================================================
// axi_master_agent.sv
//
// Sequencer + driver. The monitor lands on 25 Aug; until then the agent
// has no passive half, and this file is where it goes.
//
// is_active is read explicitly from config_db rather than relying on
// uvm_agent's field automation, so the lookup is visible. A passive
// agent builds neither sequencer nor driver -- which is what makes the
// same agent reusable on a second port when the interconnect lands.
//======================================================================

class axi_master_agent extends uvm_agent;

    `uvm_component_utils(axi_master_agent)

    axi_sequencer sqr;
    axi_driver    drv;
    axi_monitor   mon;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db #(uvm_active_passive_enum)::get(this, "", "is_active", is_active))
            `uvm_info(get_type_name(),
                      "no is_active in config_db -- defaulting to UVM_ACTIVE", UVM_MEDIUM)

        // Always. The passive half is the half that is always present.
        mon = axi_monitor::type_id::create("mon", this);

        if (is_active == UVM_ACTIVE) begin
            sqr = axi_sequencer::type_id::create("sqr", this);
            drv = axi_driver   ::type_id::create("drv", this);
        end
    endfunction

    // Bottom-up: both children exist by the time this runs.
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (is_active == UVM_ACTIVE)
            drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction

endclass : axi_master_agent
