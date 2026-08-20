//======================================================================
// axi4lite_mem_slave.sv  --  v0.3
//
// AXI4-Lite memory slave.  Implements docs/dut_spec.md v0.3 section 6.
// Base 0x0000_1000, 1 KB = 256 words, word selected by ADDR[9:2].
//
// The AXI handshake skeleton is deliberately identical to
// axi4lite_reg_slave.sv -- same accept-flags, same do_write, same bypass
// muxes, same registered-response timing.  That duplication is chosen
// over a shared base module: each slave stays readable on its own, and
// the protocol logic is the part you want to be able to point at in
// isolation.  See docs/reg_slave_architecture.md for why it is shaped
// this way; only the DIFFERENCES are commented here.
//
// What this slave does NOT have, and why that matters:
//
//   - no INT_STATUS, no STATUS, no COUNTER.  A memory slave has no
//     side effects.  Spec section 6: errors are reported on the bus only.
//   - no unimplemented-offset case.  All 256 words are implemented, and
//     everything above 0x13FF is caught by the interconnect as DECERR
//     before it ever reaches here (spec section 6).
//   - no reset on the memory array.  Spec section 6: "reset does not clear
//     memory contents.  This matches real RAM."
//
// WSTRB is honoured here, where the register slave rejects any strobe
// that is not 4'b1111.  Same signal, opposite policy, by design.
//======================================================================

`timescale 1ns/1ps

module axi4lite_mem_slave #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter int NUM_WORDS  = 256
) (
    input  logic                    ACLK,
    input  logic                    ARESETn,

    // ---------------- Write address channel ----------------
    input  logic [ADDR_WIDTH-1:0]   AWADDR,
    input  logic [2:0]              AWPROT,
    input  logic                    AWVALID,
    output logic                    AWREADY,

    // ---------------- Write data channel -------------------
    input  logic [DATA_WIDTH-1:0]   WDATA,
    input  logic [DATA_WIDTH/8-1:0] WSTRB,
    input  logic                    WVALID,
    output logic                    WREADY,

    // ---------------- Write response channel ---------------
    output logic [1:0]              BRESP,
    output logic                    BVALID,
    input  logic                    BREADY,

    // ---------------- Read address channel -----------------
    input  logic [ADDR_WIDTH-1:0]   ARADDR,
    input  logic [2:0]              ARPROT,
    input  logic                    ARVALID,
    output logic                    ARREADY,

    // ---------------- Read data channel --------------------
    output logic [DATA_WIDTH-1:0]   RDATA,
    output logic [1:0]              RRESP,
    output logic                    RVALID,
    input  logic                    RREADY
);

    localparam int STRB_WIDTH = DATA_WIDTH / 8;
    localparam int WORD_BITS  = $clog2(NUM_WORDS);      // 8 for 256 words

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    //==================================================================
    // State
    //==================================================================
    logic                  aw_captured, w_captured;
    logic [ADDR_WIDTH-1:0] awaddr_q;
    logic [DATA_WIDTH-1:0] wdata_q;
    logic [STRB_WIDTH-1:0] wstrb_q;
    logic                  bvalid_q;
    logic [1:0]            bresp_q;

    logic                  rvalid_q;
    logic [1:0]            rresp_q;
    logic [DATA_WIDTH-1:0] rdata_q;

    // The memory itself.  Deliberately NOT reset -- see the always_ff
    // below.
    logic [DATA_WIDTH-1:0] mem [0:NUM_WORDS-1];

    //==================================================================
    // Handshakes -- identical in shape to the register slave
    //==================================================================
    assign AWREADY = !aw_captured && !bvalid_q;
    assign WREADY  = !w_captured  && !bvalid_q;
    assign ARREADY = !rvalid_q;

    wire aw_hs = AWVALID && AWREADY;
    wire w_hs  = WVALID  && WREADY;
    wire ar_hs = ARVALID && ARREADY;

    assign BVALID = bvalid_q;
    assign BRESP  = bresp_q;
    assign RVALID = rvalid_q;
    assign RRESP  = rresp_q;
    assign RDATA  = rdata_q;

    wire do_write = (aw_captured || aw_hs) && (w_captured || w_hs) && !bvalid_q;

    wire [ADDR_WIDTH-1:0] wr_addr = aw_captured ? awaddr_q : AWADDR;
    wire [DATA_WIDTH-1:0] wr_data = w_captured  ? wdata_q  : WDATA;
    wire [STRB_WIDTH-1:0] wr_strb = w_captured  ? wstrb_q  : WSTRB;

    //==================================================================
    // Decode.
    //
    // Misalignment is the ONLY error this slave can raise (spec section 6).
    // There is no offset check, because every word in the region is
    // implemented and the interconnect terminates anything outside it
    // with DECERR before it arrives.
    //
    // Standalone -- before the interconnect exists -- an access to 0x1400
    // WILL alias onto word 0 here.  That is not a defect in this module;
    // it is precisely the responsibility BUG-005 injects a fault into,
    // and the reason that bug lives in the interconnect rather than here.
    //==================================================================
    wire                  wr_misalign = (wr_addr[1:0] != 2'b00);
    wire [WORD_BITS-1:0]  wr_word     =  wr_addr[WORD_BITS+1:2];
    wire                  wr_error    =  wr_misalign;

    wire                  rd_misalign = (ARADDR[1:0] != 2'b00);
    wire [WORD_BITS-1:0]  rd_word     =  ARADDR[WORD_BITS+1:2];
    wire                  rd_error    =  rd_misalign;

    wire mem_write = do_write && !wr_error;

    //==================================================================
    // Write channel sequencing
    //==================================================================
    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            aw_captured <= 1'b0;
            w_captured  <= 1'b0;
            awaddr_q    <= '0;
            wdata_q     <= '0;
            wstrb_q     <= '0;
            bvalid_q    <= 1'b0;
            bresp_q     <= RESP_OKAY;
        end else begin
            if (aw_hs) awaddr_q <= AWADDR;
            if (w_hs)  begin
                wdata_q <= WDATA;
                wstrb_q <= WSTRB;
            end

            if (do_write) begin
                aw_captured <= 1'b0;
                w_captured  <= 1'b0;
            end else begin
                if (aw_hs) aw_captured <= 1'b1;
                if (w_hs)  w_captured  <= 1'b1;
            end

            if (do_write) begin
                bvalid_q <= 1'b1;
                bresp_q  <= wr_error ? RESP_SLVERR : RESP_OKAY;
            end else if (bvalid_q && BREADY) begin
                bvalid_q <= 1'b0;
            end
        end
    end

    //==================================================================
    // The memory array.
    //
    // No reset branch, and no `negedge ARESETn` in the sensitivity list.
    // Spec section 6: reset does not clear memory contents.  This is stated in
    // the spec precisely so that surviving data is not mistaken for a
    // bug during scoreboard bring-up -- and the absence of a reset here
    // is what implements it.
    //
    // Byte-lane masking is the whole job.  Note that WSTRB == 4'b0000
    // needs NO special case: every lane is simply disabled, nothing is
    // written, and BRESP is already OKAY because misalignment is the
    // only error.  Spec section 6's "legal no-op returning OKAY" is emergent
    // from the loop rather than coded as an exception -- which is the
    // opposite of the register slave, where the same pattern is an
    // explicit error (spec section 5).
    //==================================================================
    always_ff @(posedge ACLK) begin
        if (mem_write) begin
            for (int b = 0; b < STRB_WIDTH; b++) begin
                if (wr_strb[b]) mem[wr_word][8*b +: 8] <= wr_data[8*b +: 8];
            end
        end
    end

    //==================================================================
    // Read channel sequencing.
    //
    // Reads return the full 32-bit word regardless of WSTRB or anything
    // else (spec section 6).  RDATA is zeroed on an error response, per spec section 4.
    //==================================================================
    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            rvalid_q <= 1'b0;
            rresp_q  <= RESP_OKAY;
            rdata_q  <= '0;
        end else begin
            if (ar_hs) begin
                rvalid_q <= 1'b1;
                rresp_q  <= rd_error ? RESP_SLVERR : RESP_OKAY;
                rdata_q  <= rd_error ? '0          : mem[rd_word];
            end else if (rvalid_q && RREADY) begin
                rvalid_q <= 1'b0;
            end
        end
    end

    //==================================================================
    // Deliberately unused.  AWPROT/ARPROT are accepted and ignored
    // (spec section 2); the address bits above the 1 KB region belong to the
    // interconnect, not to this slave.
    //==================================================================
    wire _unused_ok = &{1'b0,
                        AWPROT, ARPROT,
                        wr_addr[ADDR_WIDTH-1:WORD_BITS+2],
                        ARADDR[ADDR_WIDTH-1:WORD_BITS+2],
                        1'b0};

endmodule : axi4lite_mem_slave
