//======================================================================
// axi_driver.sv
//
// Five independent per-channel threads, not a sequential FSM.
//
// This is the component the whole project is shaped around. Spec §3
// rule 4 makes AW and W independent channels; a driver that drives them
// in lockstep can never produce W-before-AW, so a slave that only works
// when AW arrives first would pass every test ever written against it.
// BUG-002 is exactly that class of defect, and it is invisible without
// AW-before-W stimulus.
//
// Design decisions in docs/uvm_agent_design.md. The two that shape this
// file:
//
//   item_done() fires on ACCEPTANCE, not completion. The sequence gets
//   control back as soon as a channel slot is claimed, so a read can be
//   in flight alongside a write -- which spec §1 permits and which F24
//   (STATUS.busy) requires in order to be observable at all.
//
//   Two INDEPENDENT slots, one write and one read. dispatch() blocks on
//   the slot matching the transaction's kind, so a read never waits for
//   a write's B response.
//======================================================================

class axi_driver extends uvm_driver #(axi_transaction);

    `uvm_component_utils(axi_driver)

    virtual axi4lite_if vif;

    // Spec §1: one write and one read may be in flight simultaneously.
    // Two semaphores rather than one is the whole of that requirement.
    semaphore write_slot;
    semaphore read_slot;

    // Per-channel work queues. The same transaction handle is handed to
    // several threads: AW reads addr, W reads data/strb, B writes resp
    // back. One object, three channels -- see the design note §1.
    mailbox #(axi_transaction) aw_q;
    mailbox #(axi_transaction) w_q;
    mailbox #(axi_transaction) b_q;
    mailbox #(axi_transaction) ar_q;
    mailbox #(axi_transaction) r_q;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        write_slot = new(1);
        read_slot  = new(1);
        aw_q = new();  w_q = new();  b_q = new();
        ar_q = new();  r_q = new();
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        // Always check the return. A null virtual interface surfaces
        // hundreds of nanoseconds later as a null-handle crash with
        // nothing pointing at the cause.
        if (!uvm_config_db #(virtual axi4lite_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no virtual interface 'vif' in config_db")
    endfunction

    //==================================================================
    task run_phase(uvm_phase phase);
        drive_idle();

        // Spec §1: the testbench deasserts ARESETn on an active edge.
        // `wait` rather than @(posedge) so an already-released reset does
        // not hang the driver forever.
        wait (vif.ARESETn === 1'b1);
        `uvm_info(get_type_name(), "reset released; starting channel threads", UVM_MEDIUM)

        // join_none: the five channels run for the rest of the
        // simulation, independently of each other and of the main loop.
        fork
            aw_channel();
            w_channel();
            b_channel();
            ar_channel();
            r_channel();
        join_none

        main_loop();
    endtask

    //==================================================================
    // Sequencer handshake
    //==================================================================
    task main_loop();
        forever begin
            seq_item_port.get_next_item(req);
            dispatch(req);
            seq_item_port.item_done();      // on ACCEPTANCE, not completion
        end
    endtask

    // Blocks only on the slot for THIS transaction's kind. A read issued
    // after a write proceeds immediately; a second write waits for the
    // first write's B handshake.
    task dispatch(axi_transaction t);
        t.completed = 1'b0;
        if (t.kind == AXI_WRITE) begin
            write_slot.get(1);
            aw_q.put(t);
            w_q.put(t);
            b_q.put(t);
        end else begin
            read_slot.get(1);
            ar_q.put(t);
            r_q.put(t);
        end
    endtask

    //==================================================================
    // Idle state.
    //
    // Driven through the clocking block like everything else, so there
    // is exactly one driving process per signal and no race with the
    // channel threads.
    //==================================================================
    task drive_idle();
        @(vif.master_cb);
        vif.master_cb.AWVALID <= 1'b0;
        vif.master_cb.WVALID  <= 1'b0;
        vif.master_cb.ARVALID <= 1'b0;
        vif.master_cb.BREADY  <= 1'b0;
        vif.master_cb.RREADY  <= 1'b0;
        vif.master_cb.AWADDR  <= '0;
        vif.master_cb.AWPROT  <= '0;
        vif.master_cb.WDATA   <= '0;
        vif.master_cb.WSTRB   <= '0;
        vif.master_cb.ARADDR  <= '0;
        vif.master_cb.ARPROT  <= '0;
    endtask

    //==================================================================
    // Write address channel
    //
    // aw_delay and w_delay are counted from the same instant -- the
    // moment the transaction is dispatched -- so their relative values
    // decide the ordering. That is cg_aw_w_order's three bins produced
    // by two independent threads rather than by a mode switch.
    //
    // VALID is held until READY is SAMPLED high, never dropped early:
    // spec §3 rule 1, and the requirement a_awvalid_stable enforces.
    // BUG-001 is the deliberate violation of exactly this loop.
    //==================================================================
    task aw_channel();
        axi_transaction t;
        forever begin
            aw_q.get(t);
            repeat (t.aw_delay) @(vif.master_cb);
            vif.master_cb.AWADDR  <= t.addr;
            vif.master_cb.AWPROT  <= 3'b000;
            vif.master_cb.AWVALID <= 1'b1;
            do @(vif.master_cb); while (vif.master_cb.AWREADY !== 1'b1);
            vif.master_cb.AWVALID <= 1'b0;
        end
    endtask

    //==================================================================
    // Write data channel -- independent of AW in every respect
    //==================================================================
    task w_channel();
        axi_transaction t;
        forever begin
            w_q.get(t);
            repeat (t.w_delay) @(vif.master_cb);
            vif.master_cb.WDATA  <= t.data;
            vif.master_cb.WSTRB  <= t.strb;
            vif.master_cb.WVALID <= 1'b1;
            do @(vif.master_cb); while (vif.master_cb.WREADY !== 1'b1);
            vif.master_cb.WVALID <= 1'b0;
        end
    endtask

    //==================================================================
    // Write response channel
    //
    // b_ready_delay is applied BEFORE asserting BREADY, so if BVALID
    // arrives during that window the slave is held -- which is the
    // backpressure the DUT must tolerate (F28), and the reason
    // a_b_not_stalled exists: BVALID must not wait for BREADY.
    //==================================================================
    task b_channel();
        axi_transaction t;
        forever begin
            b_q.get(t);
            repeat (t.b_ready_delay) @(vif.master_cb);
            vif.master_cb.BREADY <= 1'b1;
            do @(vif.master_cb); while (vif.master_cb.BVALID !== 1'b1);
            t.resp = vif.master_cb.BRESP;
            vif.master_cb.BREADY <= 1'b0;
            t.completed = 1'b1;
            write_slot.put(1);              // release the write slot
        end
    endtask

    //==================================================================
    // Read address channel
    //==================================================================
    task ar_channel();
        axi_transaction t;
        forever begin
            ar_q.get(t);
            repeat (t.ar_delay) @(vif.master_cb);
            vif.master_cb.ARADDR  <= t.addr;
            vif.master_cb.ARPROT  <= 3'b000;
            vif.master_cb.ARVALID <= 1'b1;
            do @(vif.master_cb); while (vif.master_cb.ARREADY !== 1'b1);
            vif.master_cb.ARVALID <= 1'b0;
        end
    endtask

    //==================================================================
    // Read data channel -- the only place rdata is captured
    //==================================================================
    task r_channel();
        axi_transaction t;
        forever begin
            r_q.get(t);
            repeat (t.r_ready_delay) @(vif.master_cb);
            vif.master_cb.RREADY <= 1'b1;
            do @(vif.master_cb); while (vif.master_cb.RVALID !== 1'b1);
            t.rdata = vif.master_cb.RDATA;
            t.resp  = vif.master_cb.RRESP;
            vif.master_cb.RREADY <= 1'b0;
            t.completed = 1'b1;
            read_slot.put(1);               // release the read slot
        end
    endtask

endclass : axi_driver
