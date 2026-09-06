//======================================================================
// axi4lite_reg_slave.sv  --  v0.3
//
// AXI4-Lite register-file slave.  Implements docs/dut_spec.md v0.3 section 5,
// with the error precedence of section 4 and the registered-response timing
// frozen in section 3.
//
// Architecture rationale lives in docs/reg_slave_architecture.md.
// The three things worth understanding before reading the code:
//
//   1. AW and W have INDEPENDENT accept-flags, not a shared state
//      machine.  Spec section 3 rule 4 permits W before AW, and a sequential
//      FSM could never accept that ordering.
//
//   2. do_write is combinational and true on the cycle the LATER half
//      is accepted.  Registering it into bvalid_q therefore places
//      BVALID exactly one cycle after that accept, which is what
//      a_bvalid_not_early and a_b_not_stalled jointly require.
//
//   3. Errors are a strict priority cascade, so exactly one error is
//      ever true and exactly one INT_STATUS bit is ever set (section 4).
//
// WHAT COMES FROM axi4lite_reg_pkg AND WHAT DOES NOT
//
// Every name, offset, width, reset value and implemented-bit mask below
// is imported from rtl/gen/axi4lite_reg_pkg.sv, which is generated from
// scripts/regmap.yaml along with the RAL model and docs/register_map.md.
// Narrowing a field in the YAML narrows the flop here.
//
// The BEHAVIOUR is not generated and is not meant to be. W1C
// set-beats-clear, CTRL[1]'s self-clearing pulse, STATUS.error's
// transparency rule and COUNTER's reset-over-increment priority are one
// paragraph of the spec each, and the always_ff blocks below cite those
// paragraphs directly. A template would be a worse expression of them.
//======================================================================

`timescale 1ns/1ps

module axi4lite_reg_slave #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
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

    // Indices, offsets, widths, resets and masks -- generated from
    // scripts/regmap.yaml. R_CTRL..R_ID, CONFIG_W, CONFIG_RESET,
    // ID_RESET, REG_IMPL_MSB and the rest all arrive here.
    import axi4lite_reg_pkg::*;

    localparam int STRB_WIDTH = DATA_WIDTH / 8;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    //==================================================================
    // State
    //==================================================================

    // Write channel bookkeeping
    logic                    aw_captured, w_captured;
    logic [ADDR_WIDTH-1:0]   awaddr_q;
    logic [DATA_WIDTH-1:0]   wdata_q;
    logic [STRB_WIDTH-1:0]   wstrb_q;
    logic                    bvalid_q;
    logic [1:0]              bresp_q;

    // Read channel bookkeeping.  No address latch is needed: ARREADY is
    // gated on !rvalid_q, so the response is computed and registered on
    // the very cycle AR is accepted, straight from ARADDR.
    logic                    rvalid_q;
    logic [1:0]              rresp_q;
    logic [DATA_WIDTH-1:0]   rdata_q;

    // Register bank -- stored at implemented width only, so reserved bits
    // physically cannot retain data (spec section 5, feature F13).
    logic                            ctrl_enable;    // CTRL.enable
    logic [CONFIG_W-1:0]             config_q;
    logic [INT_ENABLE_W-1:0]         int_enable_q;
    logic [INT_STATUS_W-1:0]         int_status_q;
    logic [SCRATCH_W-1:0]            scratch_q;
    logic [COUNTER_W-1:0]            counter_q;
    logic                            status_error;   // STATUS.error

    //==================================================================
    // Handshakes
    //
    // Each READY has two terms:
    //   !x_captured : we are not already holding an unmatched half
    //   !bvalid_q   : no write response is outstanding
    //
    // The second term is what satisfies a_single_outstanding_write.  It
    // is load-bearing: on the cycle after do_write both accept-flags have
    // cleared, so without it AWREADY would rise again while BVALID is
    // still waiting for BREADY.
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

    //==================================================================
    // Write commit
    //
    // True on the cycle the LATER of the two halves is accepted, whether
    // that half arrives first, second, or in the same cycle as the other.
    //==================================================================
    wire do_write = (aw_captured || aw_hs) && (w_captured || w_hs) && !bvalid_q;

    // Bypass muxes.  On the commit cycle one half may have been latched
    // several cycles ago while the other is being accepted right now and
    // is therefore only on the bus, not in its latch.  Omitting these is
    // the classic same-cycle-AW+W bug: the write uses stale latch data.
    wire [ADDR_WIDTH-1:0] wr_addr = aw_captured ? awaddr_q : AWADDR;
    wire [DATA_WIDTH-1:0] wr_data = w_captured  ? wdata_q  : WDATA;
    wire [STRB_WIDTH-1:0] wr_strb = w_captured  ? wstrb_q  : WSTRB;

    //==================================================================
    // Decode and error precedence -- spec section 4, section 5
    //
    // Note the decode is on the FULL offset, not ADDR[7:2].  Offset
    // 0x100 must return SLVERR, not alias onto CTRL.  See dut_spec section 10
    // revision 1.
    //
    // The cascade is strict, so exactly one err_* is ever true.
    //==================================================================
    wire                    wr_misalign    = (wr_addr[1:0] != 2'b00);
    wire                    wr_implemented = (wr_addr[REG_IMPL_MSB:REG_IMPL_LSB] == '0);
    wire [REG_INDEX_W-1:0]  wr_idx         =  wr_addr[REG_INDEX_MSB:REG_INDEX_LSB];

    wire wr_err_misalign = wr_misalign;
    wire wr_err_unimpl   = !wr_misalign && !wr_implemented;
    wire wr_err_strobe   = !wr_misalign && wr_implemented && !(&wr_strb);
    wire wr_error        = wr_err_misalign || wr_err_unimpl || wr_err_strobe;

    wire                    rd_misalign    = (ARADDR[1:0] != 2'b00);
    wire                    rd_implemented = (ARADDR[REG_IMPL_MSB:REG_IMPL_LSB] == '0);
    wire [REG_INDEX_W-1:0]  rd_idx         =  ARADDR[REG_INDEX_MSB:REG_INDEX_LSB];

    wire rd_err_misalign = rd_misalign;
    wire rd_err_unimpl   = !rd_misalign && !rd_implemented;
    wire rd_error        = rd_err_misalign || rd_err_unimpl;

    // A register write that actually takes effect.  Every error path is
    // excluded here, which is how spec section 4's "no error condition modifies
    // any register or memory state" is enforced -- in one place.
    wire reg_write = do_write && !wr_error;

    wire reset_stats_pulse = reg_write && (wr_idx == R_CTRL)       && wr_data[CTRL_RESET_STATS_LSB];
    wire w1c_write         = reg_write && (wr_idx == R_INT_STATUS);

    //==================================================================
    // INT_STATUS event sources -- spec section 5
    //
    // Read and write paths can each raise an event in the same cycle, so
    // the misaligned and unimplemented terms are OR-ed across both.
    // Partial-strobe is write-only: reads carry no WSTRB.
    //==================================================================
    wire ev_unimpl   = (do_write && wr_err_unimpl)   || (ar_hs && rd_err_unimpl);
    wire ev_misalign = (do_write && wr_err_misalign) || (ar_hs && rd_err_misalign);
    wire ev_strobe   = (do_write && wr_err_strobe);
    wire ev_overflow = ctrl_enable && !reset_stats_pulse && (counter_q == '1);

    // Assembled by generated bit position rather than by concatenation
    // order, so reordering the fields in regmap.yaml cannot silently
    // reassign an event to the wrong bit.
    logic [INT_STATUS_W-1:0] int_set;
    always_comb begin
        int_set                              = '0;
        int_set[INT_STATUS_UNIMPL_LSB]       = ev_unimpl;
        int_set[INT_STATUS_MISALIGN_LSB]     = ev_misalign;
        int_set[INT_STATUS_STROBE_LSB]       = ev_strobe;
        int_set[INT_STATUS_OVERFLOW_LSB]     = ev_overflow;
    end

    //==================================================================
    // STATUS.busy -- write path only, spec section 5.
    //
    // If it covered reads, a read of STATUS would itself be an in-flight
    // read and the bit could never be observed as 0.
    //==================================================================
    wire busy = aw_captured || w_captured || bvalid_q;

    //==================================================================
    // Read data mux, with reserved bits masked HERE rather than at the
    // storage element.  Both work; masking on read keeps the stored
    // width honest and makes F13 one obvious line per register.
    //
    // CTRL[1] (reset_stats) reads 0 unconditionally -- it is a command
    // bit, not state.  Spec section 5, clarified in v0.3.
    //==================================================================
    logic [31:0] rd_mux;

    always_comb begin
        // All eight values of a 3-bit selector are enumerated, so the
        // case is inherently full and needs no default.
        case (rd_idx)
            // CTRL and STATUS are assembled bit by bit rather than from a
            // width, because neither is plain storage: CTRL[1] is a
            // command bit that reads 0 unconditionally, and STATUS's two
            // bits come from different places entirely.
            R_CTRL       : rd_mux = {{(DATA_WIDTH-CTRL_W){1'b0}}, 1'b0, ctrl_enable};
            R_STATUS     : rd_mux = {{(DATA_WIDTH-STATUS_W){1'b0}}, status_error, busy};
            R_CONFIG     : rd_mux = {{(DATA_WIDTH-CONFIG_W){1'b0}}, config_q};
            R_INT_ENABLE : rd_mux = {{(DATA_WIDTH-INT_ENABLE_W){1'b0}}, int_enable_q};
            R_INT_STATUS : rd_mux = {{(DATA_WIDTH-INT_STATUS_W){1'b0}}, int_status_q};
            R_SCRATCH    : rd_mux = scratch_q;
            R_COUNTER    : rd_mux = {{(DATA_WIDTH-COUNTER_W){1'b0}}, counter_q};
            R_ID         : rd_mux = ID_RESET;
        endcase
    end

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

            // Both halves are consumed together on the commit cycle.
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
    // Read channel sequencing.
    //
    // ARREADY = !rvalid_q gives single-outstanding for free, and returns
    // high one cycle after r_done -- which is exactly the back-to-back
    // shape c_b2b_read covers.
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
                rdata_q  <= rd_error ? 32'h0       : rd_mux;
            end else if (rvalid_q && RREADY) begin
                rvalid_q <= 1'b0;
            end
        end
    end

    //==================================================================
    // Register bank.
    //
    // STATUS, COUNTER and ID are RO: they fall through to the default
    // and are silently discarded, with BRESP already OKAY (spec section 5).
    // INT_STATUS is W1C and is handled in its own block below.
    //==================================================================
    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            ctrl_enable  <= CTRL_ENABLE_RESET[0];
            config_q     <= CONFIG_RESET    [CONFIG_W-1:0];      // 0x0000_00FF
            int_enable_q <= INT_ENABLE_RESET[INT_ENABLE_W-1:0];
            scratch_q    <= SCRATCH_RESET   [SCRATCH_W-1:0];
        end else if (reg_write) begin
            case (wr_idx)
                R_CTRL       : ctrl_enable  <= wr_data[CTRL_ENABLE_LSB];
                R_CONFIG     : config_q     <= wr_data[CONFIG_W-1:0];
                R_INT_ENABLE : int_enable_q <= wr_data[INT_ENABLE_W-1:0];
                R_SCRATCH    : scratch_q    <= wr_data[SCRATCH_W-1:0];
                default      : ;          // RO and W1C handled elsewhere
            endcase
        end
    end

    //==================================================================
    // COUNTER -- 16 bits, spec section 5.
    //
    // reset_stats takes priority over increment: if both apply on the
    // same cycle the result is 0.  The branch ORDER is the spec rule.
    //==================================================================
    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn)               counter_q <= COUNTER_COUNT_RESET[COUNTER_W-1:0];
        else if (reset_stats_pulse) counter_q <= '0;
        else if (ctrl_enable)       counter_q <= counter_q + 1'b1;
    end

    //==================================================================
    // INT_STATUS -- W1C with real event sources, spec section 5.
    //
    // "Set beats simultaneous clear -- the event must not be lost."  That
    // sentence IS the if/else-if ordering below.  Swapping the branches
    // is a plausible RTL defect and is what directed test F23 exists to
    // catch.
    //==================================================================
    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            int_status_q <= INT_STATUS_RESET[INT_STATUS_W-1:0];
        end else begin
            for (int i = 0; i < INT_STATUS_W; i++) begin
                if (int_set[i])                        int_status_q[i] <= 1'b1;
                else if (w1c_write && wr_data[i])      int_status_q[i] <= 1'b0;
            end
        end
    end

    //==================================================================
    // STATUS.error -- spec section 5, clarified in v0.3.
    //
    // Updated by every completed register transaction EXCEPT a read of
    // STATUS itself, which is transparent.  A misaligned access that
    // happens to decode to the STATUS offset is not a read of STATUS:
    // it errors, and it sets the bit.
    //
    // Write wins a same-cycle tie, per spec.
    //
    // The update happens at the internal commit point, one cycle ahead
    // of the response handshake.  Single-outstanding means any read
    // issued after that handshake still observes the new value, so the
    // distinction is invisible at transaction level.
    //==================================================================
    wire rd_is_status_read = ar_hs && !rd_error && (rd_idx == R_STATUS);

    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn)                              status_error <= 1'b0;
        else if (do_write)                         status_error <= wr_error;
        else if (ar_hs && !rd_is_status_read)      status_error <= rd_error;
    end

    //==================================================================
    // Deliberately unused.  AWPROT/ARPROT are accepted and ignored
    // (spec section 2), and only the low 12 address bits are decoded -- the
    // interconnect owns everything above that.  Named explicitly so
    // lint stays clean and the omission reads as intent, not oversight.
    //==================================================================
    wire _unused_ok = &{1'b0,
                        AWPROT, ARPROT,
                        wr_addr[ADDR_WIDTH-1:REG_IMPL_MSB+1],
                        ARADDR [ADDR_WIDTH-1:REG_IMPL_MSB+1],
                        1'b0};

endmodule : axi4lite_reg_slave
