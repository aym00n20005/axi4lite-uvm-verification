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
//
//----------------------------------------------------------------------
// CYCLE-LEVEL TIMING, added for cg_valid_delay and cg_backpressure.
//
// coverage_status.md listed three covergroups as "not modelled" with one
// cause: "these need per-cycle timing the monitor does not record". It
// also named the fix -- cg_aw_w_order left that list when this file began
// timestamping the AW and W accepts, and "the same treatment extends to
// the other three". This is that treatment.
//
// Each channel task counts its OWN cycles and stores the result in the
// beat object it hands on. Nothing is shared between the tasks, which
// matters: they all wake on the same clocking event, so a counter one
// task increments and another reads would be a race whose outcome
// depends on task creation order.
//
// What is measured is what a slave EXPERIENCES:
//
//   the idle gap before a request VALID rises -- not the driver's
//   aw_delay, which is counted from an instant no pin shows;
//
//   the cycles a response spent asserted with the master's READY low.
//
// Sampling the driver's knobs instead would measure the testbench's
// intentions, which is the failure this component exists to avoid.
//======================================================================

class axi_monitor extends uvm_component;

    `uvm_component_utils(axi_monitor)

    virtual axi4lite_if vif;

    uvm_analysis_port #(axi_transaction) ap;

    // Reset is not a transaction and does not belong on ap. cg_reset's
    // three bins need an event of their own.
    uvm_analysis_port #(axi_reset_event) rst_ap;

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
    int unsigned n_resets = 0;

    // Transactions abandoned because reset fell while they were in
    // flight. Counted, not silently dropped: check_phase must be able to
    // tell "the response never came" from "reset took it away".
    int unsigned n_flushed = 0;

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
        ap     = new("ap", this);
        rst_ap = new("rst_ap", this);
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
            reset_watch();
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
        int unsigned idle;          // cycles with AWVALID low since the last accept
        int unsigned gap;           // that count, frozen at the rising edge
        bit          prev_valid;

        idle = 0; gap = 0; prev_valid = 1'b0;
        forever begin
            @(vif.monitor_cb);

            // Rising edge of AWVALID: the idle run that just ended is
            // what the slave saw between this transaction and the last.
            if (vif.monitor_cb.AWVALID === 1'b1 && !prev_valid) gap = idle;
            if (vif.monitor_cb.AWVALID !== 1'b1) idle++;
            prev_valid = (vif.monitor_cb.AWVALID === 1'b1);

            if (vif.monitor_cb.AWVALID === 1'b1 && vif.monitor_cb.AWREADY === 1'b1) begin
                beat = axi_transaction::type_id::create("aw_beat");
                beat.addr            = vif.monitor_cb.AWADDR;
                beat.obs_valid_delay = gap;
                aw_time              = $realtime;
                aw_accepted.put(beat);
                idle = 0;
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
        int unsigned idle;
        int unsigned gap;
        bit          prev_valid;

        idle = 0; gap = 0; prev_valid = 1'b0;
        forever begin
            @(vif.monitor_cb);

            if (vif.monitor_cb.ARVALID === 1'b1 && !prev_valid) gap = idle;
            if (vif.monitor_cb.ARVALID !== 1'b1) idle++;
            prev_valid = (vif.monitor_cb.ARVALID === 1'b1);

            if (vif.monitor_cb.ARVALID === 1'b1 && vif.monitor_cb.ARREADY === 1'b1) begin
                beat = axi_transaction::type_id::create("ar_beat");
                beat.addr            = vif.monitor_cb.ARADDR;
                beat.obs_valid_delay = gap;
                // Was a write in flight at the instant this read sampled
                // the DUT? Answered from this component's OWN accept
                // queues -- the driver is not asked. Spec section 1
                // permits one read and one write at once, and the
                // scoreboard cannot order a read against a write's
                // internal commit. BUG-012.
                beat.obs_overlapped_write =
                    (aw_accepted.num() != 0) || (w_accepted.num() != 0);
                ar_accepted.put(beat);
                idle = 0;
            end
        end
    endtask

    //==================================================================
    // Completion. The response handshake is what makes a transaction
    // real, and it is where the halves are joined.
    //==================================================================
    task b_watch();
        axi_transaction aw, w, t;
        int unsigned stall;         // cycles BVALID was high with BREADY low

        stall = 0;
        forever begin
            @(vif.monitor_cb);

            // Counted BEFORE the handshake test, so the cycle on which
            // BREADY finally rises is not counted as a stall.
            if (vif.monitor_cb.BVALID === 1'b1 && vif.monitor_cb.BREADY !== 1'b1) stall++;

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

                    // Timing, observed. The idle gap travelled here in
                    // the AW beat; the stall was counted above.
                    t.obs_valid_delay  = aw.obs_valid_delay;
                    t.obs_backpressure = stall;
                    t.obs_timing_valid = 1'b1;

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
                stall = 0;
            end
        end
    endtask

    task r_watch();
        axi_transaction ar, t;
        int unsigned stall;

        stall = 0;
        forever begin
            @(vif.monitor_cb);

            if (vif.monitor_cb.RVALID === 1'b1 && vif.monitor_cb.RREADY !== 1'b1) stall++;

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

                    t.obs_valid_delay      = ar.obs_valid_delay;
                    t.obs_backpressure     = stall;
                    t.obs_timing_valid     = 1'b1;
                    t.obs_overlapped_write = ar.obs_overlapped_write;

                    n_reads++;
                    `uvm_info(get_type_name(),
                              $sformatf("observed %s rdata=0x%08h",
                                        t.convert2string(), t.rdata), UVM_HIGH)
                    ap.write(t);
                end
                stall = 0;
            end
        end
    endtask

    //==================================================================
    // Reset.
    //
    // Two jobs, and the second is the one that is easy to forget.
    //
    // 1. Publish an event carrying whether anything was in flight, which
    //    is cg_reset's three bins. The answer comes from this
    //    component's OWN accept queues -- the driver is not asked.
    //
    // 2. FLUSH those queues. A transaction interrupted by reset never
    //    gets its response: spec section 3 rule 7 puts every VALID low
    //    while ARESETn is low, so the B or R that would have retired the
    //    beat can never arrive. Left in place, the beat would surface at
    //    check_phase as "AW accepted with no B response" -- a failure
    //    report for the DUT behaving exactly as specified.
    //
    //    They are COUNTED as they are flushed, so an abandoned
    //    transaction is still visible in the report rather than
    //    disappearing. "Reset took it away" and "the response never
    //    came" are different statements and the log must be able to make
    //    both.
    //==================================================================
    task reset_watch();
        axi_reset_event ev;
        axi_transaction junk;
        int unsigned    low_cycles;

        forever begin
            // Watch the pin, not a clocking-block input: the point is to
            // see reset the moment it asserts, and it asserts
            // asynchronously (spec section 1).
            @(negedge vif.ARESETn);

            ev = axi_reset_event::type_id::create("rst_ev");
            ev.during_write = (aw_accepted.num() != 0) || (w_accepted.num() != 0);
            ev.during_read  = (ar_accepted.num() != 0);

            while (aw_accepted.num() != 0) begin aw_accepted.get(junk); n_flushed++; end
            while (w_accepted.num()  != 0) begin w_accepted.get(junk);  n_flushed++; end
            while (ar_accepted.num() != 0) begin ar_accepted.get(junk); n_flushed++; end

            low_cycles = 0;
            fork
                begin : count_low
                    forever begin @(vif.monitor_cb); low_cycles++; end
                end
                @(posedge vif.ARESETn);
            join_any
            disable count_low;

            ev.cycles_low = low_cycles;
            n_resets++;
            `uvm_info(get_type_name(), ev.convert2string(), UVM_MEDIUM)
            rst_ap.write(ev);
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
                  $sformatf("observed %0d writes, %0d reads, %0d resets, %0d beats flushed by reset",
                            n_writes, n_reads, n_resets, n_flushed), UVM_LOW)
    endfunction

endclass : axi_monitor
