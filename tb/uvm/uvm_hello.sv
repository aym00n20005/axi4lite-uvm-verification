//======================================================================
// uvm_hello.sv  --  UVM fundamentals on THIS project's hierarchy
//
// Schedule row 20 Aug: phases, uvm_component hierarchy, config_db,
// factory. Hello-world on EDA Playground.
//
// Deliberately self-contained: no DUT, no interface, no pins. The point
// is to see the four mechanisms work in isolation before they are load-
// bearing. The virtual interface arrives on 22 Aug with axi_transaction.
//
// It is NOT a generic hello-world. The hierarchy is the one in the
// README's environment diagram, so what you fill in from 22 Aug slots
// into components that already exist and already print their phases.
//
//----------------------------------------------------------------------
// EDA Playground setup:
//   Testbench + Design language : SystemVerilog/Verilog
//   UVM version                 : UVM 1.2
//   Tools & Simulators          : Aldec Riviera-PRO
//   Leave the design pane EMPTY. Paste this file into the testbench pane.
//   Tick "Open EPWave after run" if you want a (blank) waveform.
//
// Run it twice. First as-is. Then change the last line of this file from
//   run_test("axi_base_test")  to  run_test("axi_factory_test")
// and run again WITHOUT editing anything else. That second run is the
// factory lesson: different behaviour, zero edits to the environment.
//======================================================================

`include "uvm_macros.svh"
import uvm_pkg::*;

//======================================================================
// 1. uvm_object -- the transient thing
//
// A sequence item is a uvm_OBJECT, not a uvm_component. It is created,
// passed around, and garbage collected. It has no phases and no place
// in the hierarchy, because it does not persist.
//
// This is the single most useful distinction in UVM:
//   uvm_component  static, lives for the whole simulation, has phases
//   uvm_object     transient data, no phases, no hierarchy
//======================================================================
class axi_hello_item extends uvm_sequence_item;

    rand bit [31:0] addr;
    rand bit [31:0] data;

    // Field automation: gives print/copy/compare/pack for free.
    `uvm_object_utils_begin(axi_hello_item)
        `uvm_field_int(addr, UVM_ALL_ON | UVM_HEX)
        `uvm_field_int(data, UVM_ALL_ON | UVM_HEX)
    `uvm_object_utils_end

    // Note the constructor signature: name only.
    // A component's takes (name, parent). Objects have no parent.
    function new(string name = "axi_hello_item");
        super.new(name);
    endfunction

    constraint c_aligned { addr[1:0] == 2'b00; }

endclass


//======================================================================
// 2. The sequence -- also an object
//
// start_item / finish_item is the handshake with the sequencer. The
// sequence BLOCKS inside finish_item until the driver calls item_done().
// That back-pressure is what stops a sequence racing ahead of the bus.
//======================================================================
class axi_hello_seq extends uvm_sequence #(axi_hello_item);

    `uvm_object_utils(axi_hello_seq)

    function new(string name = "axi_hello_seq");
        super.new(name);
    endfunction

    task body();
        axi_hello_item it;
        repeat (3) begin
            it = axi_hello_item::type_id::create("it");
            start_item(it);                    // waits for driver readiness
            if (!it.randomize())
                `uvm_error(get_type_name(), "randomize failed")
            `uvm_info(get_type_name(),
                      $sformatf("sending  addr=0x%08h data=0x%08h", it.addr, it.data),
                      UVM_LOW)
            finish_item(it);                   // blocks until item_done()
        end
    endtask

endclass


//======================================================================
// 3. The driver -- a component, so it has phases
//
// run_phase is the ONLY phase that consumes time. Everything else is a
// function and must return immediately.
//
// `drive` is marked virtual purely so axi_factory_test can override this
// class with a subclass. That is the factory lesson in one keyword.
//======================================================================
class axi_driver extends uvm_driver #(axi_hello_item);

    `uvm_component_utils(axi_driver)

    // Component constructor: (name, parent). This is what puts it in the
    // hierarchy, and it is why get_full_name() works.
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        `uvm_info(get_type_name(), "build_phase", UVM_LOW)
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            seq_item_port.get_next_item(req);   // req is inherited from uvm_driver
            drive(req);
            seq_item_port.item_done();          // releases the sequence
        end
    endtask

    virtual task drive(axi_hello_item it);
        `uvm_info(get_type_name(),
                  $sformatf("  driving addr=0x%08h data=0x%08h", it.addr, it.data),
                  UVM_LOW)
        #10ns;
        // From 23 Aug this becomes five fork...join_none per-channel
        // threads. Nothing about the phase structure changes.
    endtask

endclass


//======================================================================
// The factory-override subclass. Nothing else in the environment knows
// this type exists.
//======================================================================
class axi_driver_slow extends axi_driver;

    `uvm_component_utils(axi_driver_slow)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task drive(axi_hello_item it);
        `uvm_info(get_type_name(),
                  $sformatf("  driving SLOWLY addr=0x%08h", it.addr), UVM_LOW)
        #100ns;
    endtask

endclass


//======================================================================
// 4. The monitor -- passive, and shares NO state with the driver
//
// This one fabricates an item, because uvm_hello has no pins to watch.
// The real axi_monitor (tb/agent/axi_monitor.sv, 25 Aug) reconstructs
// from vif.monitor_cb alone and has no handle to the driver -- see the
// header of that file for why that rule matters more than it looks.
//======================================================================
class axi_monitor extends uvm_component;

    `uvm_component_utils(axi_monitor)

    uvm_analysis_port #(axi_hello_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        `uvm_info(get_type_name(), "build_phase", UVM_LOW)
    endfunction

    task run_phase(uvm_phase phase);
        axi_hello_item it;
        #45ns;
        it = axi_hello_item::type_id::create("observed");
        it.addr = 32'h0000_0014;
        it.data = 32'hDEAD_C0DE;
        `uvm_info(get_type_name(), "PLACEHOLDER observation -> analysis port", UVM_LOW)
        ap.write(it);
    endtask

endclass


//======================================================================
// 5. The scoreboard -- receives via an analysis imp
//======================================================================
class axi_scoreboard extends uvm_component;

    `uvm_component_utils(axi_scoreboard)

    uvm_analysis_imp #(axi_hello_item, axi_scoreboard) analysis_export;

    int received = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        analysis_export = new("analysis_export", this);
    endfunction

    // The imp requires exactly this function name.
    function void write(axi_hello_item it);
        received++;
        `uvm_info(get_type_name(),
                  $sformatf("scoreboard saw addr=0x%08h data=0x%08h", it.addr, it.data),
                  UVM_LOW)
    endfunction

    // check_phase runs after run_phase has finished. Use it for
    // end-of-test assertions, never for anything time-consuming.
    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (received == 0)
            `uvm_error(get_type_name(), "scoreboard received nothing")
        else
            `uvm_info(get_type_name(),
                      $sformatf("check_phase: %0d item(s) received", received), UVM_LOW)
    endfunction

endclass


//======================================================================
// 6. The agent -- builds children conditionally
//
// A passive agent has no driver and no sequencer: it only observes.
// That is what makes the same agent reusable on a second port later.
//
// The is_active lookup is written out explicitly rather than relying on
// uvm_agent's field automation, because seeing the get() is the lesson.
//======================================================================
class axi_master_agent extends uvm_agent;

    `uvm_component_utils(axi_master_agent)

    uvm_sequencer #(axi_hello_item) sqr;
    axi_driver                      drv;
    axi_monitor                     mon;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db #(uvm_active_passive_enum)::get(this, "", "is_active", is_active))
            `uvm_info(get_type_name(),
                      "no is_active in config_db -- defaulting to UVM_ACTIVE", UVM_LOW)

        `uvm_info(get_type_name(),
                  $sformatf("build_phase, is_active=%s", is_active.name()), UVM_LOW)

        // The monitor always exists. The active half is conditional.
        mon = axi_monitor::type_id::create("mon", this);

        if (is_active == UVM_ACTIVE) begin
            sqr = uvm_sequencer #(axi_hello_item)::type_id::create("sqr", this);
            drv = axi_driver::type_id::create("drv", this);
        end
    endfunction

    // connect_phase is BOTTOM-UP: every child already exists by now.
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (is_active == UVM_ACTIVE) begin
            drv.seq_item_port.connect(sqr.seq_item_export);
            `uvm_info(get_type_name(), "connect_phase: driver <-> sequencer", UVM_LOW)
        end
    endfunction

endclass


//======================================================================
// 7. The environment
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
        `uvm_info(get_type_name(), "build_phase", UVM_LOW)
        agent = axi_master_agent::type_id::create("agent", this);
        sb    = axi_scoreboard::type_id::create("sb", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        agent.mon.ap.connect(sb.analysis_export);
        `uvm_info(get_type_name(), "connect_phase: monitor -> scoreboard", UVM_LOW)
    endfunction

endclass


//======================================================================
// 8. The test
//
// Objections are what keep run_phase alive. Drop the last one and the
// simulation ends immediately -- a sequence still running is simply cut
// off. This is the most common "my test does nothing" cause in UVM.
//======================================================================
class axi_base_test extends uvm_test;

    `uvm_component_utils(axi_base_test)

    axi_env env;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        `uvm_info(get_type_name(), "build_phase -- creating env", UVM_LOW)

        // Set BEFORE the child's build_phase runs. Legal because
        // build_phase is TOP-DOWN: this executes before agent's does.
        uvm_config_db #(uvm_active_passive_enum)::set(this, "env.agent", "is_active", UVM_ACTIVE);

        env = axi_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        `uvm_info(get_type_name(), "end_of_elaboration -- hierarchy below", UVM_LOW)
        uvm_top.print_topology();
    endfunction

    task run_phase(uvm_phase phase);
        axi_hello_seq seq;
        phase.raise_objection(this, "running hello sequence");
        seq = axi_hello_seq::type_id::create("seq");
        seq.start(env.agent.sqr);
        #100ns;
        phase.drop_objection(this, "hello sequence done");
    endtask

endclass


//======================================================================
// 9. The factory lesson
//
// This test changes the driver's behaviour without touching axi_env,
// axi_master_agent, or axi_driver. That is the whole argument for
// ::type_id::create() over new(): the type is decided at run time.
//
// It is also how your 16-test list in the verification plan reuses one
// environment.
//======================================================================
class axi_factory_test extends axi_base_test;

    `uvm_component_utils(axi_factory_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        // Override BEFORE super.build_phase, so it is registered before
        // the agent creates its driver.
        set_type_override_by_type(axi_driver::get_type(), axi_driver_slow::get_type());
        `uvm_info(get_type_name(), "factory override: axi_driver -> axi_driver_slow", UVM_LOW)
        super.build_phase(phase);
    endfunction

endclass


//======================================================================
// 10. Top module
//======================================================================
module tb_top;

    initial begin
        $display("\n================ UVM hello -- this project's hierarchy ================\n");
        // Change to "axi_factory_test" for the second run.
        run_test("axi_base_test");
    end

endmodule
