//======================================================================
// axi4lite_if.sv  —  v0.2
// AXI4-Lite interface + bindable protocol checker
//
// Matches docs/dut_spec.md v0.2. Assumes:
//   - one outstanding write, one outstanding read
//   - registered slave: BVALID/RVALID assert no earlier than the cycle
//     AFTER the accepts that enable them (spec §3, frozen decision)
//
// READ THIS BEFORE USING IT. In particular understand:
//   - why VALID-stability uses |=> and not |->
//   - what `disable iff (!ARESETn)` does to every property below
//   - why the response-ordering checks trigger on VALID alone, not on
//     VALID && READY  (see the note above a_bvalid_not_early)
//======================================================================

interface axi4lite_if #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
) (
    input logic ACLK,
    input logic ARESETn
);

    localparam int STRB_WIDTH = DATA_WIDTH / 8;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    // ---------------- Write address channel ----------------
    logic [ADDR_WIDTH-1:0] AWADDR;
    logic [2:0]            AWPROT;
    logic                  AWVALID;
    logic                  AWREADY;

    // ---------------- Write data channel -------------------
    logic [DATA_WIDTH-1:0] WDATA;
    logic [STRB_WIDTH-1:0] WSTRB;
    logic                  WVALID;
    logic                  WREADY;

    // ---------------- Write response channel ---------------
    logic [1:0]            BRESP;
    logic                  BVALID;
    logic                  BREADY;

    // ---------------- Read address channel -----------------
    logic [ADDR_WIDTH-1:0] ARADDR;
    logic [2:0]            ARPROT;
    logic                  ARVALID;
    logic                  ARREADY;

    // ---------------- Read data channel --------------------
    logic [DATA_WIDTH-1:0] RDATA;
    logic [1:0]            RRESP;
    logic                  RVALID;
    logic                  RREADY;

    //------------------------------------------------------------------
    // Clocking blocks.
    // Sampling at #1step avoids races with DUT drives on the same edge.
    //------------------------------------------------------------------
    clocking master_cb @(posedge ACLK);
        default input #1step output #1ns;
        output AWADDR, AWPROT, AWVALID;
        input  AWREADY;
        output WDATA, WSTRB, WVALID;
        input  WREADY;
        input  BRESP, BVALID;
        output BREADY;
        output ARADDR, ARPROT, ARVALID;
        input  ARREADY;
        input  RDATA, RRESP, RVALID;
        output RREADY;
    endclocking

    clocking monitor_cb @(posedge ACLK);
        default input #1step;
        input AWADDR, AWPROT, AWVALID, AWREADY;
        input WDATA, WSTRB, WVALID, WREADY;
        input BRESP, BVALID, BREADY;
        input ARADDR, ARPROT, ARVALID, ARREADY;
        input RDATA, RRESP, RVALID, RREADY;
    endclocking

    modport master  (clocking master_cb,  input ACLK, ARESETn);
    modport monitor (clocking monitor_cb, input ACLK, ARESETn);

endinterface : axi4lite_if


//======================================================================
// axi4lite_protocol_checker
//
// Bind to the DUT rather than instantiating, so DUT source stays clean:
//   bind axi4lite_reg_slave axi4lite_protocol_checker chk (.*);
//======================================================================

module axi4lite_protocol_checker #(
    parameter int ADDR_WIDTH  = 32,
    parameter int DATA_WIDTH  = 32,
    // Set 0 for the memory slave, which has no alignment-independent
    // behaviour worth a separate checker instance.
    parameter bit CHECK_ALIGN = 1
) (
    input logic                    ACLK,
    input logic                    ARESETn,
    input logic [ADDR_WIDTH-1:0]   AWADDR,
    input logic                    AWVALID,
    input logic                    AWREADY,
    input logic [DATA_WIDTH-1:0]   WDATA,
    input logic [DATA_WIDTH/8-1:0] WSTRB,
    input logic                    WVALID,
    input logic                    WREADY,
    input logic [1:0]              BRESP,
    input logic                    BVALID,
    input logic                    BREADY,
    input logic [ADDR_WIDTH-1:0]   ARADDR,
    input logic                    ARVALID,
    input logic                    ARREADY,
    input logic [DATA_WIDTH-1:0]   RDATA,
    input logic [1:0]              RRESP,
    input logic                    RVALID,
    input logic                    RREADY
);

    default clocking @(posedge ACLK); endclocking
    default disable iff (!ARESETn);

    //==================================================================
    // Handshake tracking (single outstanding write, single read)
    //
    // aw_pend / w_pend  : this half of a write has been accepted and the
    //                     B response has not yet completed
    // ar_pend           : AR accepted, R not yet completed
    //
    // Cleared on the response handshake, but re-armed in the same cycle
    // if a new accept happens simultaneously — otherwise a back-to-back
    // transaction would be missed.
    //==================================================================
    logic aw_pend, w_pend, ar_pend;

    wire aw_acc = AWVALID && AWREADY;
    wire w_acc  = WVALID  && WREADY;
    wire b_done = BVALID  && BREADY;
    wire ar_acc = ARVALID && ARREADY;
    wire r_done = RVALID  && RREADY;

    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            aw_pend <= 1'b0;
            w_pend  <= 1'b0;
            ar_pend <= 1'b0;
        end else begin
            if (b_done) begin
                aw_pend <= aw_acc;
                w_pend  <= w_acc;
            end else begin
                if (aw_acc) aw_pend <= 1'b1;
                if (w_acc)  w_pend  <= 1'b1;
            end

            if (r_done)       ar_pend <= ar_acc;
            else if (ar_acc)  ar_pend <= 1'b1;
        end
    end

    //==================================================================
    // 1. VALID, once asserted, must stay asserted until READY.
    //
    // |=> not |->  : the obligation lands on the NEXT cycle, because on
    // this cycle we have already observed VALID high and READY low.
    //==================================================================
    property p_valid_stable(valid, ready);
        (valid && !ready) |=> valid;
    endproperty

    a_awvalid_stable : assert property (p_valid_stable(AWVALID, AWREADY))
        else $error("AWVALID deasserted before AWREADY");
    a_wvalid_stable  : assert property (p_valid_stable(WVALID,  WREADY))
        else $error("WVALID deasserted before WREADY");
    a_arvalid_stable : assert property (p_valid_stable(ARVALID, ARREADY))
        else $error("ARVALID deasserted before ARREADY");
    a_bvalid_stable  : assert property (p_valid_stable(BVALID,  BREADY))
        else $error("BVALID deasserted before BREADY");
    a_rvalid_stable  : assert property (p_valid_stable(RVALID,  RREADY))
        else $error("RVALID deasserted before RREADY");

    //==================================================================
    // 2. Payload stable while VALID high and READY low.
    //==================================================================
    a_awaddr_stable : assert property ((AWVALID && !AWREADY) |=> $stable(AWADDR))
        else $error("AWADDR changed while AWVALID held");
    a_wdata_stable  : assert property ((WVALID  && !WREADY)  |=> $stable(WDATA))
        else $error("WDATA changed while WVALID held");
    a_wstrb_stable  : assert property ((WVALID  && !WREADY)  |=> $stable(WSTRB))
        else $error("WSTRB changed while WVALID held");
    a_araddr_stable : assert property ((ARVALID && !ARREADY) |=> $stable(ARADDR))
        else $error("ARADDR changed while ARVALID held");
    a_rdata_stable  : assert property ((RVALID  && !RREADY)  |=> $stable(RDATA))
        else $error("RDATA changed while RVALID held");
    a_rresp_stable  : assert property ((RVALID  && !RREADY)  |=> $stable(RRESP))
        else $error("RRESP changed while RVALID held");
    a_bresp_stable  : assert property ((BVALID  && !BREADY)  |=> $stable(BRESP))
        else $error("BRESP changed while BVALID held");

    //==================================================================
    // 3. Response ordering — spec §3 rules 5 and 6.
    //
    // These trigger on VALID alone, NOT on VALID && READY.
    //
    // Why it matters: a slave could assert BVALID far too early, and if
    // the master is slow to raise BREADY, the missing accepts may have
    // arrived by the time the handshake completes. A check gated on
    // BVALID && BREADY would then pass on a genuinely broken DUT. The
    // requirement is about the moment of ASSERTION, so the check has to
    // be too. (v0.1 of this file got this wrong.)
    //==================================================================
    a_bvalid_not_early : assert property (BVALID |-> (aw_pend && w_pend))
        else $error("BVALID asserted before both AW and W were accepted");

    a_rvalid_not_early : assert property (RVALID |-> ar_pend)
        else $error("RVALID asserted before AR was accepted");

    //==================================================================
    // 4. Responses must not wait for their READY — spec §3 rule 7.
    //    Once both write halves are accepted, B must appear within a
    //    bounded number of cycles regardless of BREADY.
    //    Bound is generous; tighten it once the DUT latency is known.
    //==================================================================
    a_b_not_stalled : assert property
        ((aw_pend && w_pend) |-> ##[0:8] BVALID)
        else $error("BVALID did not appear after both AW and W accepted");

    a_r_not_stalled : assert property
        (ar_pend |-> ##[0:8] RVALID)
        else $error("RVALID did not appear after AR accepted");

    //==================================================================
    // 5. Single outstanding — spec §1.
    //    No further AW or W accepted while a complete write awaits its
    //    response, unless that response completes in the same cycle.
    //==================================================================
    a_single_outstanding_write : assert property
        ((aw_pend && w_pend && !b_done) |-> !(aw_acc || w_acc))
        else $error("Second write accepted while a B response was pending");

    a_single_outstanding_read : assert property
        ((ar_pend && !r_done) |-> !ar_acc)
        else $error("Second read accepted while an R response was pending");

    //==================================================================
    // 6. Alignment — spec §4. Misaligned must return SLVERR, never OKAY.
    //==================================================================
    if (CHECK_ALIGN) begin : g_align
        a_misaligned_write_errors : assert property
            ((aw_acc && (AWADDR[1:0] != 2'b00)) |-> ##[1:8] (BVALID && BRESP != 2'b00))
            else $error("Misaligned write did not return an error response");

        a_misaligned_read_errors : assert property
            ((ar_acc && (ARADDR[1:0] != 2'b00)) |-> ##[1:8] (RVALID && RRESP != 2'b00))
            else $error("Misaligned read did not return an error response");
    end

    //==================================================================
    // 7. No X/Z on control signals out of reset.
    //    Catches uninitialised registers early — otherwise they surface
    //    much later as baffling scoreboard mismatches.
    //==================================================================
    a_no_x_valids : assert property
        (!$isunknown({AWVALID, WVALID, BVALID, ARVALID, RVALID}))
        else $error("X or Z on a VALID signal");
    a_no_x_readys : assert property
        (!$isunknown({AWREADY, WREADY, BREADY, ARREADY, RREADY}))
        else $error("X or Z on a READY signal");

    //==================================================================
    // 8. Reset behaviour.
    //    This one deliberately overrides the default disable, because it
    //    is about what happens WHILE reset is low.
    //==================================================================
    a_reset_valids_low : assert property (
        disable iff (1'b0)
        (!ARESETn) |-> (!AWVALID && !WVALID && !BVALID && !ARVALID && !RVALID)
    ) else $error("A VALID was high during reset");

    //==================================================================
    // 9. Cover properties.
    //
    // These are not optional decoration. An assertion that never fires
    // on a bus that is never stressed proves nothing. c_w_before_aw in
    // particular is the check that your driver is genuinely running
    // independent per-channel threads rather than lockstepping AW and W
    // — if it stays uncovered, none of your protocol testing is real.
    //==================================================================
    c_aw_before_w     : cover property (aw_acc ##[1:$] w_acc);
    c_w_before_aw     : cover property (w_acc  ##[1:$] aw_acc);
    c_aw_w_same_cycle : cover property (aw_acc && w_acc);

    c_write_backpressure : cover property
        (AWVALID && !AWREADY ##1 AWVALID && !AWREADY ##1 AWVALID && !AWREADY);
    c_read_backpressure : cover property
        (RVALID && !RREADY ##1 RVALID && !RREADY);

    c_b2b_write : cover property (b_done ##1 aw_acc);
    c_b2b_read  : cover property (r_done ##1 ar_acc);

    c_resp_okay   : cover property ((b_done && BRESP == 2'b00) or (r_done && RRESP == 2'b00));
    c_resp_slverr : cover property ((b_done && BRESP == 2'b10) or (r_done && RRESP == 2'b10));
    c_resp_decerr : cover property ((b_done && BRESP == 2'b11) or (r_done && RRESP == 2'b11));

    c_partial_strobe : cover property (w_acc && (WSTRB != 4'b1111));
    c_zero_strobe    : cover property (w_acc && (WSTRB == 4'b0000));
    c_misaligned_aw  : cover property (aw_acc && (AWADDR[1:0] != 2'b00));
    c_misaligned_ar  : cover property (ar_acc && (ARADDR[1:0] != 2'b00));

endmodule : axi4lite_protocol_checker
