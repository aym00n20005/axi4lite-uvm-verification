//======================================================================
// axi_monitor.sv
//
// Fully passive. Reconstructs transactions from PINS ONLY.
//
// Verification plan section 4: "Monitor is fully passive and reconstructs
// transactions from pins only. It shares no state with the driver, so a
// driver defect cannot mask itself."
//
// That rule is the whole point of this file, and it is easy to break by
// accident. The tempting shortcut is to have the driver publish what it
// intended to drive -- one line, and the scoreboard then compares the
// driver against itself. Every driver bug becomes invisible in the same
// instant: a driver that sends the wrong address would be checked against
// the wrong address and pass.
//
// So this component has:
//   - no handle to axi_driver
//   - no access to its mailboxes or its req
//   - nothing but vif.monitor_cb, which is input-only by construction
//
// It keeps its OWN accept-flags, deliberately duplicating logic the driver
// and the DUT both also have. The duplication is the mechanism, not an
// oversight: three independent implementations of "when is a write
// complete" have to agree, and if they disagree something is wrong.
//======================================================================

class axi_monitor extends uvm_component;

    `uvm_component_utils(axi_monitor)

    virtual axi4lite_if vif;

    uvm_analysis_port #(axi_transaction) ap;

    // The monitor's own view of what the bus has accepted. Single
    // outstanding per spec section 1, so these never hold more than one
    // entry -- but a mailbox rather than a flag, because a back-to-back
    // transaction can accept a new beat on the same cycle a response
    // completes, and put/get are atomic where a flag would race.
    mailbox #(axi_transaction) aw_accepted;
    mailbox #(axi_transaction) w_accepted;
    mailbox #(axi_transaction) ar_accepted;

    int unsigned n_writes = 0;
    int unsigned n_reads  = 0;

    // Accept times for the write halves, so the ordering can be OBSERVED
    // rather than taken from the stimulus that requested it.
    realtime aw_time, w_time;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        aw_accepted = new();
        w_accepted  = new();
        ar_accepted = new();
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db #(virtual axi4lite_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "no virtual interface 'vif' in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        // No wait for reset. A transaction cannot complete during reset,
        // and watching from time zero means a VALID that appears when it
        // should not is still observed.
        fork
            aw_watch();
            w_watch();
            b_watch();
            ar_watch();
            r_watch();
        join_none
    endtask

    //==================================================================
    // Address and data acceptance.
    //
    // monitor_cb samples every input at #1step before the edge, so a
    // handshake seen here means VALID and READY were both high for the
    // cycle that just ended. That is the definition of a transfer --
    // spec section 3.
    //==================================================================
    task aw_watch();
        axi_transaction beat;
        forever begin
            @(vif.monitor_cb);
            if (vif.monitor_cb.AWVALID === 1'b1 && vif.monitor_cb.AWREADY === 1'b1) begin
                beat = axi_transaction::type_id::create("aw_beat");
                beat.addr = vif.monitor_cb.AWADDR;
                aw_time   = $realtime;
                aw_accepted.put(beat);
            end
        end
    endtask

    task w_watch();
        axi_transaction beat;
        forever begin
            @(vif.monitor_cb);
            if (vif.monitor_cb.WVALID === 1'b1 && vif.monitor_cb.WREADY === 1'b1) begin
                beat = axi_transaction::type_id::create("w_beat");
                beat.data = vif.monitor_cb.WDATA;
                beat.strb = vif.monitor_cb.WSTRB;
                w_time    = $realtime;
                w_accepted.put(beat);
            end
        end
    endtask

    task ar_watch();
        axi_transaction beat;
        forever begin
            @(vif.monitor_cb);
            if (vif.monitor_cb.ARVALID === 1'b1 && vif.monitor_cb.ARREADY === 1'b1) begin
                beat = axi_transaction::type_id::create("ar_beat");
                beat.addr = vif.monitor_cb.ARADDR;
                ar_accepted.put(beat);
            end
        end
    endtask

    //==================================================================
    // Completion. The response handshake is what makes a transaction
    // real, and it is where the halves are joined.
    //==================================================================
    task b_watch();
        axi_transaction aw, w, t;
        forever begin
            @(vif.monitor_cb);
            if (vif.monitor_cb.BVALID === 1'b1 && vif.monitor_cb.BREADY === 1'b1) begin

                // Spec section 3 rule 5: BVALID must not assert until both
                // AW and W have been accepted. If either queue is empty
                // the DUT has violated the protocol -- the same defect
                // a_bvalid_not_early catches, found here independently.
                if (aw_accepted.num() == 0 || w_accepted.num() == 0) begin
                    `uvm_error(get_type_name(),
                        $sformatf("B response with no matching accepts (aw=%0d w=%0d) -- spec section 3 rule 5",
                                  aw_accepted.num(), w_accepted.num()))
                end
                else begin
                    aw_accepted.get(aw);
                    w_accepted.get(w);

                    t = axi_transaction::type_id::create("mon_wr");
                    t.kind      = AXI_WRITE;
                    t.addr      = aw.addr;
                    t.data      = w.data;
                    t.strb      = w.strb;
                    t.resp      = vif.monitor_cb.BRESP;
                    t.completed = 1'b1;

                    // Observed, not requested. Equal timestamps mean the
                    // two halves were accepted on the same clock edge.
                    if      (aw_time <  w_time) t.obs_order = ORDER_AW_FIRST;
                    else if (w_time  <  aw_time) t.obs_order = ORDER_W_FIRST;
                    else                         t.obs_order = ORDER_SAME_CYCLE;
                    t.obs_order_valid = 1'b1;

                    n_writes++;
                    `uvm_info(get_type_name(),
                              $sformatf("observed %s", t.convert2string()), UVM_HIGH)
                    ap.write(t);
                end
            end
        end
    endtask

    task r_watch();
        axi_transaction ar, t;
        forever begin
            @(vif.monitor_cb);
            if (vif.monitor_cb.RVALID === 1'b1 && vif.monitor_cb.RREADY === 1'b1) begin

                // Spec section 3 rule 6, the read-side equivalent.
                if (ar_accepted.num() == 0) begin
                    `uvm_error(get_type_name(),
                        "R response with no matching AR accept -- spec section 3 rule 6")
                end
                else begin
                    ar_accepted.get(ar);

                    t = axi_transaction::type_id::create("mon_rd");
                    t.kind      = AXI_READ;
                    t.addr      = ar.addr;
                    t.rdata     = vif.monitor_cb.RDATA;
                    t.resp      = vif.monitor_cb.RRESP;
                    t.completed = 1'b1;

                    n_reads++;
                    `uvm_info(get_type_name(),
                              $sformatf("observed %s rdata=0x%08h",
                                        t.convert2string(), t.rdata), UVM_HIGH)
                    ap.write(t);
                end
            end
        end
    endtask

    // Anything still sitting in a queue at end of test is a write or read
    // whose response never arrived.
    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (aw_accepted.num() != 0)
            `uvm_error(get_type_name(),
                $sformatf("%0d AW accepted with no B response", aw_accepted.num()))
        if (w_accepted.num() != 0)
            `uvm_error(get_type_name(),
                $sformatf("%0d W accepted with no B response", w_accepted.num()))
        if (ar_accepted.num() != 0)
            `uvm_error(get_type_name(),
                $sformatf("%0d AR accepted with no R response", ar_accepted.num()))
        `uvm_info(get_type_name(),
                  $sformatf("observed %0d writes, %0d reads", n_writes, n_reads), UVM_LOW)
    endfunction

endclass : axi_monitor
