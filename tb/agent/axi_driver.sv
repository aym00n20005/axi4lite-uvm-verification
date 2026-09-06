//======================================================================
// axi_driver.sv
//
// Five independent per-channel threads, not a sequential FSM.
//
// This is the component the whole project is shaped around. Spec section 3
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
//   in flight alongside a write -- which spec section 1 permits and which F24
//   (STATUS.busy) requires in order to be observable at all.
//
//   Two INDEPENDENT slots, one write and one read. dispatch() blocks on
//   the slot matching the transaction's kind, so a read never waits for
//   a write's B response.
//======================================================================

class axi_driver extends uvm_driver #(axi_transaction);

    `uvm_component_utils(axi_driver)

    virtual axi4lite_if vif;

    // Spec section 1: one write and one read may be in flight simultaneously.
    // Two semaphores rather than one is the whole of that requirement.
    semaphore write_slot;
    semaphore read_slot;

    // Per-channel work queues. The same transaction handle is handed to
    // several threads: AW reads addr, W reads data/strb, B writes resp
    // back. One object, three channels -- see the design note section 1.
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
    // Reset bookkeeping. Counted, not just handled: a transaction reset
    // took away never reaches the monitor, so the end-of-test check
    // "monitor saw what the sequence issued" needs the difference
    // explained rather than tolerated.
    //==================================================================
    int unsigned aborted_writes = 0;
    int unsigned aborted_reads  = 0;
    int unsigned n_resets       = 0;

    //==================================================================
    task run_phase(uvm_phase phase);
        drive_idle();

        // main_loop is started ONCE and is never killed. It owns the
        // sequencer handshake, and tearing down a component in the middle
        // of get_next_item/item_done leaves the sequencer waiting for an
        // item_done that will never come -- a hang whose cause is three
        // components away from where it shows up.
        //
        // The five channel threads ARE killed and restarted, because they
        // are the ones holding VALIDs high across a reset that spec
        // section 3 rule 7 requires to be low.
        fork
            main_loop();
            reset_supervisor();
        join_none
    endtask

    //==================================================================
    // Start the channels, run them until reset falls, tear them down,
    // clean up, and start them again.
    //
    // The fork/join_any + `disable fork` idiom is the standard one and
    // the nesting is not decoration: the extra `fork ... join` wrapper
    // limits `disable fork` to the threads started inside it, so it
    // cannot reach main_loop or this loop itself.
    //==================================================================
    task reset_supervisor();
        forever begin
            // `wait` rather than @(posedge): reset may already be
            // released by the time this runs, and an edge that has
            // happened never happens again.
            wait (vif.ARESETn === 1'b1);
            `uvm_info(get_type_name(), "reset released; starting channel threads", UVM_MEDIUM)

            fork begin
                fork
                    aw_channel();
                    w_channel();
                    b_channel();
                    ar_channel();
                    r_channel();
                    @(negedge vif.ARESETn);
                join_any
                disable fork;
            end join

            if (vif.ARESETn !== 1'b1) begin
                n_resets++;
                `uvm_info(get_type_name(),
                          "ARESETn fell -- abandoning in-flight transactions", UVM_MEDIUM)
                on_reset();
                // Do not race the deassertion: wait for it explicitly
                // before looking at ARESETn again.
                @(posedge vif.ARESETn);
            end
        end
    endtask

    //==================================================================
    // What reset actually costs, and why each line is here.
    //==================================================================
    task on_reset();
        axi_transaction t;

        // 1. Put the pins back. The channel threads died mid-handshake,
        //    possibly with a VALID high; a_reset_valids_low watches
        //    during reset and would fire, correctly.
        drive_idle();

        // 2. Retire everything queued or in flight. Each one gets
        //    completed=1 so any sequence blocked on `wait (t.completed)`
        //    is released, and aborted=1 so it can tell what happened.
        //
        //    b_q and r_q are the ones that matter -- a transaction is in
        //    exactly one of them from dispatch until its response -- so
        //    they are drained last and are the ones counted. Draining
        //    aw_q/w_q/ar_q first prevents a restarted channel thread
        //    from driving a beat belonging to a dead transaction.
        while (aw_q.num() != 0) void'(aw_q.try_get(t));
        while (w_q.num()  != 0) void'(w_q.try_get(t));
        while (ar_q.num() != 0) void'(ar_q.try_get(t));

        while (b_q.num() != 0) begin
            void'(b_q.try_get(t));
            t.resp = 2'b00; t.aborted = 1'b1; t.completed = 1'b1;
            aborted_writes++;
        end
        while (r_q.num() != 0) begin
            void'(r_q.try_get(t));
            t.resp = 2'b00; t.rdata = 32'h0; t.aborted = 1'b1; t.completed = 1'b1;
            aborted_reads++;
        end

        // 3. Release the slots. main_loop may be blocked inside
        //    dispatch() on one of these, and nothing else will ever
        //    release it -- the b_channel thread that would have is dead.
        //
        //    try_get-then-put rather than a bare put: a bare put on a
        //    slot that was already free makes the count 2 and quietly
        //    permits two outstanding writes, which spec section 1 forbids
        //    and a_single_outstanding_write would then catch several
        //    thousand cycles later.
        void'(write_slot.try_get(1)); write_slot.put(1);
        void'(read_slot .try_get(1)); read_slot .put(1);
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
    // ALIGNMENT NOTE, and it applies to every channel task below.
    //
    // Each task begins with @(vif.master_cb) BEFORE driving anything.
    // Without it the task resumes from its mailbox at whatever time the
    // sequencer handshake happened -- which is not necessarily a clocking
    // event -- and with a zero delay there is nothing to re-align it.
    //
    // A clocking-block output assignment applies at the NEXT clocking
    // event plus the output skew. Unaligned, the assert and the deassert
    // can resolve to the SAME event, and the later write wins:
    //
    //     AWVALID <= 1'b1;                       -> event E
    //     do @(cb); while (!AWREADY);            -> returns at E
    //     AWVALID <= 1'b0;                       -> also E, and wins
    //
    // AWADDR is written once so it survives; AWVALID is written twice so
    // it never rises. That is a bus with the payload driven, VALID low,
    // READY high and nothing ever happening -- which is precisely what
    // axi_mem_test hung on for 40 cycles on 27 Aug.
    //
    // It worked on the register slave by luck of when dispatch landed
    // relative to the clock, which is the worst kind of working. The
    // non-UVM benches never showed it because every task in sanity_tb.sv
    // starts with @(posedge ACLK).
    //==================================================================

    //==================================================================
    // Write address channel
    //
    // aw_delay and w_delay are counted from the same instant -- the
    // moment the transaction is dispatched -- so their relative values
    // decide the ordering. That is cg_aw_w_order's three bins produced
    // by two independent threads rather than by a mode switch.
    //
    // VALID is held until READY is SAMPLED high, never dropped early:
    // spec section 3 rule 1, and the requirement a_awvalid_stable enforces.
    // BUG-001 is the deliberate violation of exactly this loop.
    //==================================================================
    task aw_channel();
        axi_transaction t;
        forever begin
            aw_q.get(t);
            @(vif.master_cb);                       // align to the clock grid
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
            @(vif.master_cb);                       // align to the clock grid
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
            @(vif.master_cb);                       // align to the clock grid
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
            @(vif.master_cb);                       // align to the clock grid
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
            @(vif.master_cb);                       // align to the clock grid
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
