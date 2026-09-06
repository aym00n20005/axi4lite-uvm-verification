//======================================================================
// axi4lite_interconnect.sv  --  v0.3
//
// One master port, two slave ports, address decode and response mux.
// Implements docs/dut_spec.md v0.3 section 7, decoding per section 4.
//
// Architecture rationale: docs/interconnect_architecture.md.
//
// THE THREE THINGS WORTH UNDERSTANDING BEFORE READING THE CODE
//
//   1. The decode is NOT a single address bit.  Spec section 4 puts an
//      unmapped gap at 0x1400-0x1FFF, which a naive ADDR[12] decode
//      would route to the memory slave.  That gap exists precisely so
//      the decode is non-trivial and DECERR is reachable from an
//      address that looks plausible.  It is also spec section 9's
//      BUG-005 injection.
//
//   2. W can arrive before AW, and when it does the destination is not
//      yet known.  Spec section 3 rule 4 makes the ordering the
//      master's choice; spec section 7 names this as the hard part.
//      The W beat is therefore HELD in a one-entry buffer -- one entry
//      is sufficient because section 1 caps outstanding writes at one --
//      and replayed to the selected slave once AW decodes.  This is the
//      whole reason the write path is a state machine rather than a mux.
//
//   3. DECERR is generated HERE and nowhere else.  Neither slave
//      contains a code path that can emit 2'b11 (they define only
//      RESP_OKAY and RESP_SLVERR), so an unmapped transaction is
//      answered by this module and never forwarded.  Spec section 4:
//      DECERR means "could not be routed"; SLVERR means "a slave owns
//      this address and rejected the access".
//
// REGISTERED RESPONSES
//
// The frozen timing decision in spec section 3 -- BVALID and RVALID
// assert no earlier than the cycle AFTER the accepts that enable them --
// applies to this module too, because the bound checker on the master
// port uses registered pending-flags.  A DECERR is therefore also
// registered: the state machine reaches its response state one cycle
// after collecting the halves, which is exactly one cycle, not zero.
//
// AN OBSERVATION ABOUT THE SLAVE PORTS
//
// AW and W are forwarded together, so on a slave port they are always
// accepted in the same cycle.  W-before-AW is a property of the MASTER
// port only, and c_w_before_aw on a slave-port checker instance will
// correctly stay at zero.  That is the interconnect absorbing the
// ordering, not the environment failing to exercise it.
//======================================================================

`timescale 1ns/1ps

module axi4lite_interconnect #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
) (
    input  logic                    ACLK,
    input  logic                    ARESETn,

    //================ Master-facing port (this module is the slave) ====
    input  logic [ADDR_WIDTH-1:0]   S_AWADDR,
    input  logic [2:0]              S_AWPROT,
    input  logic                    S_AWVALID,
    output logic                    S_AWREADY,
    input  logic [DATA_WIDTH-1:0]   S_WDATA,
    input  logic [DATA_WIDTH/8-1:0] S_WSTRB,
    input  logic                    S_WVALID,
    output logic                    S_WREADY,
    output logic [1:0]              S_BRESP,
    output logic                    S_BVALID,
    input  logic                    S_BREADY,
    input  logic [ADDR_WIDTH-1:0]   S_ARADDR,
    input  logic [2:0]              S_ARPROT,
    input  logic                    S_ARVALID,
    output logic                    S_ARREADY,
    output logic [DATA_WIDTH-1:0]   S_RDATA,
    output logic [1:0]              S_RRESP,
    output logic                    S_RVALID,
    input  logic                    S_RREADY,

    //================ Slave port 0 -- register file @ 0x0000_0000 ======
    output logic [ADDR_WIDTH-1:0]   M0_AWADDR,
    output logic [2:0]              M0_AWPROT,
    output logic                    M0_AWVALID,
    input  logic                    M0_AWREADY,
    output logic [DATA_WIDTH-1:0]   M0_WDATA,
    output logic [DATA_WIDTH/8-1:0] M0_WSTRB,
    output logic                    M0_WVALID,
    input  logic                    M0_WREADY,
    input  logic [1:0]              M0_BRESP,
    input  logic                    M0_BVALID,
    output logic                    M0_BREADY,
    output logic [ADDR_WIDTH-1:0]   M0_ARADDR,
    output logic [2:0]              M0_ARPROT,
    output logic                    M0_ARVALID,
    input  logic                    M0_ARREADY,
    input  logic [DATA_WIDTH-1:0]   M0_RDATA,
    input  logic [1:0]              M0_RRESP,
    input  logic                    M0_RVALID,
    output logic                    M0_RREADY,

    //================ Slave port 1 -- memory @ 0x0000_1000 =============
    output logic [ADDR_WIDTH-1:0]   M1_AWADDR,
    output logic [2:0]              M1_AWPROT,
    output logic                    M1_AWVALID,
    input  logic                    M1_AWREADY,
    output logic [DATA_WIDTH-1:0]   M1_WDATA,
    output logic [DATA_WIDTH/8-1:0] M1_WSTRB,
    output logic                    M1_WVALID,
    input  logic                    M1_WREADY,
    input  logic [1:0]              M1_BRESP,
    input  logic                    M1_BVALID,
    output logic                    M1_BREADY,
    output logic [ADDR_WIDTH-1:0]   M1_ARADDR,
    output logic [2:0]              M1_ARPROT,
    output logic                    M1_ARVALID,
    input  logic                    M1_ARREADY,
    input  logic [DATA_WIDTH-1:0]   M1_RDATA,
    input  logic [1:0]              M1_RRESP,
    input  logic                    M1_RVALID,
    output logic                    M1_RREADY
);

    localparam int STRB_WIDTH = DATA_WIDTH / 8;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    //==================================================================
    // Address map -- spec section 4, and the ONLY place it is written.
    //==================================================================
    localparam logic [31:0] REG_BASE  = 32'h0000_0000;
    localparam logic [31:0] REG_LIMIT = 32'h0000_0FFF;   // 4 KB
    localparam logic [31:0] MEM_BASE  = 32'h0000_1000;
    localparam logic [31:0] MEM_LIMIT = 32'h0000_13FF;   // 1 KB
    //   0x0000_1400 and above: unmapped -> DECERR.  Note the gap: it is
    //   inside what ADDR[12] alone would call "memory".

    typedef enum logic [1:0] { DEST_REG, DEST_MEM, DEST_ERR } dest_e;

    // Range comparison, not a bit test.  Writing this as ADDR[12] or
    // ADDR[13] is the BUG-005 injection: 0x1400 would then reach the
    // memory slave, which owns only 0x1000-0x13FF, and be answered as
    // if it were word 0x100 of a 256-word array.
    //
    // The register region's LOWER bound is absent on purpose.  REG_BASE
    // is 0, so `a >= REG_BASE` is vacuously true for an unsigned address
    // and Verilator says so (UNSIGNED).  Deleting a term because it is
    // vacuous today is how a decode quietly breaks when the region
    // moves, so the assumption is checked at time zero rather than left
    // implicit.  A comparison that cannot fail is the same defect class
    // as a cover point that cannot fail -- see docs/bug_reports/BUG-007.
    function automatic dest_e decode(input logic [ADDR_WIDTH-1:0] a);
        if (a <= REG_LIMIT)                  return DEST_REG;
        if (a >= MEM_BASE && a <= MEM_LIMIT) return DEST_MEM;
        return DEST_ERR;
    endfunction

    initial begin
        if (REG_BASE != 32'h0000_0000)
            $fatal(1, "axi4lite_interconnect: decode() omits the REG_BASE lower bound because REG_BASE is 0. It is now 0x%08h -- restore the term.", REG_BASE);
        if (REG_LIMIT >= MEM_BASE)
            $fatal(1, "axi4lite_interconnect: register and memory regions overlap");
    end

    //==================================================================
    // WRITE PATH
    //
    //   W_COLLECT : accept AW and W from the master, in either order and
    //               independently.  This is where a W that arrives first
    //               is held.
    //   W_FWD     : both halves in hand and the destination known; drive
    //               them at the selected slave until each is accepted.
    //   W_WAIT_B  : slave response outstanding.
    //   W_RESP    : drive S_BVALID until the master accepts.  Also the
    //               state a DECERR jumps straight to.
    //==================================================================
    typedef enum logic [1:0] { W_COLLECT, W_FWD, W_WAIT_B, W_RESP } wstate_e;

    wstate_e                  wstate;
    logic                     aw_held, w_held;
    logic [ADDR_WIDTH-1:0]    aw_addr_q;
    logic [2:0]               aw_prot_q;
    logic [DATA_WIDTH-1:0]    w_data_q;
    logic [STRB_WIDTH-1:0]    w_strb_q;
    dest_e                    w_dest_q;
    logic [1:0]               bresp_q;
    logic                     aw_sent, w_sent;

    // Accepting is gated on W_COLLECT alone, which is what gives
    // single-outstanding (spec section 1) for free: leaving the state
    // drops both READYs, and returning to it on the master's B handshake
    // raises them again on the very next cycle -- the shape c_b2b_write
    // covers.
    assign S_AWREADY = (wstate == W_COLLECT) && !aw_held;
    assign S_WREADY  = (wstate == W_COLLECT) && !w_held;

    wire s_aw_hs = S_AWVALID && S_AWREADY;
    wire s_w_hs  = S_WVALID  && S_WREADY;

    // Bypass muxes.  On the cycle the LATER half is accepted its latch
    // has not been written yet, so the decision to leave W_COLLECT --
    // and the destination that decision depends on -- must look at the
    // bus.  Omitting this is the same class of defect as a register
    // slave that uses stale latch data on a same-cycle AW+W.
    wire [ADDR_WIDTH-1:0] aw_addr_now = aw_held ? aw_addr_q : S_AWADDR;
    wire                  w_both_now  = (aw_held || s_aw_hs) && (w_held || s_w_hs);
    dest_e                w_dest_now;
    assign w_dest_now = decode(aw_addr_now);

    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            wstate    <= W_COLLECT;
            aw_held   <= 1'b0;
            w_held    <= 1'b0;
            aw_addr_q <= '0;
            aw_prot_q <= '0;
            w_data_q  <= '0;
            w_strb_q  <= '0;
            w_dest_q  <= DEST_REG;
            bresp_q   <= RESP_OKAY;
            aw_sent   <= 1'b0;
            w_sent    <= 1'b0;
        end else begin
            if (s_aw_hs) begin
                aw_addr_q <= S_AWADDR;
                aw_prot_q <= S_AWPROT;
                aw_held   <= 1'b1;
            end
            if (s_w_hs) begin
                w_data_q <= S_WDATA;
                w_strb_q <= S_WSTRB;
                w_held   <= 1'b1;
            end

            unique case (wstate)

                W_COLLECT : if (w_both_now) begin
                    w_dest_q <= w_dest_now;
                    if (w_dest_now == DEST_ERR) begin
                        // Not forwarded to any slave -- spec section 4.
                        // One cycle from here to W_RESP, which is what
                        // keeps the response registered.
                        bresp_q <= RESP_DECERR;
                        wstate  <= W_RESP;
                    end else begin
                        aw_sent <= 1'b0;
                        w_sent  <= 1'b0;
                        wstate  <= W_FWD;
                    end
                end

                W_FWD : begin
                    if (m_aw_hs) aw_sent <= 1'b1;
                    if (m_w_hs)  w_sent  <= 1'b1;
                    if ((aw_sent || m_aw_hs) && (w_sent || m_w_hs))
                        wstate <= W_WAIT_B;
                end

                W_WAIT_B : if (m_b_hs) begin
                    bresp_q <= m_bresp;
                    wstate  <= W_RESP;
                end

                W_RESP : if (S_BVALID && S_BREADY) begin
                    aw_held <= 1'b0;
                    w_held  <= 1'b0;
                    wstate  <= W_COLLECT;
                end

                default : wstate <= W_COLLECT;
            endcase
        end
    end

    assign S_BVALID = (wstate == W_RESP);
    assign S_BRESP  = bresp_q;

    //==================================================================
    // READ PATH -- the same shape, minus the two-halves problem.  AR
    // carries the address, so the destination is known at the accept.
    //==================================================================
    typedef enum logic [1:0] { R_IDLE, R_FWD, R_WAIT_R, R_RESP } rstate_e;

    rstate_e               rstate;
    logic [ADDR_WIDTH-1:0] ar_addr_q;
    logic [2:0]            ar_prot_q;
    dest_e                 r_dest_q;
    logic [DATA_WIDTH-1:0] rdata_q;
    logic [1:0]            rresp_q;

    assign S_ARREADY = (rstate == R_IDLE);
    wire s_ar_hs = S_ARVALID && S_ARREADY;

    always_ff @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            rstate    <= R_IDLE;
            ar_addr_q <= '0;
            ar_prot_q <= '0;
            r_dest_q  <= DEST_REG;
            rdata_q   <= '0;
            rresp_q   <= RESP_OKAY;
        end else begin
            unique case (rstate)

                R_IDLE : if (s_ar_hs) begin
                    ar_addr_q <= S_ARADDR;
                    ar_prot_q <= S_ARPROT;
                    r_dest_q  <= decode(S_ARADDR);
                    if (decode(S_ARADDR) == DEST_ERR) begin
                        // Spec section 4: RDATA is deterministic zero on
                        // any error response, so the scoreboard can check
                        // it rather than mask it.
                        rdata_q <= '0;
                        rresp_q <= RESP_DECERR;
                        rstate  <= R_RESP;
                    end else begin
                        rstate <= R_FWD;
                    end
                end

                R_FWD : if (m_ar_hs) rstate <= R_WAIT_R;

                R_WAIT_R : if (m_r_hs) begin
                    rdata_q <= m_rdata;
                    rresp_q <= m_rresp;
                    rstate  <= R_RESP;
                end

                R_RESP : if (S_RVALID && S_RREADY) rstate <= R_IDLE;

                default : rstate <= R_IDLE;
            endcase
        end
    end

    assign S_RVALID = (rstate == R_RESP);
    assign S_RDATA  = rdata_q;
    assign S_RRESP  = rresp_q;

    //==================================================================
    // Slave-port fan-out.
    //
    // Address and data are driven from the latches unconditionally, so
    // they are stable whether or not VALID is high -- a_awaddr_stable
    // and a_wdata_stable on the slave-port checker instances hold by
    // construction rather than by luck.  Only the VALIDs are steered.
    //==================================================================
    wire sel_reg_w = (w_dest_q == DEST_REG);
    wire sel_mem_w = (w_dest_q == DEST_MEM);
    wire sel_reg_r = (r_dest_q == DEST_REG);
    wire sel_mem_r = (r_dest_q == DEST_MEM);

    assign M0_AWADDR  = aw_addr_q;
    assign M0_AWPROT  = aw_prot_q;
    assign M0_WDATA   = w_data_q;
    assign M0_WSTRB   = w_strb_q;
    assign M0_ARADDR  = ar_addr_q;
    assign M0_ARPROT  = ar_prot_q;

    assign M1_AWADDR  = aw_addr_q;
    assign M1_AWPROT  = aw_prot_q;
    assign M1_WDATA   = w_data_q;
    assign M1_WSTRB   = w_strb_q;
    assign M1_ARADDR  = ar_addr_q;
    assign M1_ARPROT  = ar_prot_q;

    assign M0_AWVALID = (wstate == W_FWD) && sel_reg_w && !aw_sent;
    assign M0_WVALID  = (wstate == W_FWD) && sel_reg_w && !w_sent;
    assign M0_BREADY  = (wstate == W_WAIT_B) && sel_reg_w;
    assign M0_ARVALID = (rstate == R_FWD)  && sel_reg_r;
    assign M0_RREADY  = (rstate == R_WAIT_R) && sel_reg_r;

    assign M1_AWVALID = (wstate == W_FWD) && sel_mem_w && !aw_sent;
    assign M1_WVALID  = (wstate == W_FWD) && sel_mem_w && !w_sent;
    assign M1_BREADY  = (wstate == W_WAIT_B) && sel_mem_w;
    assign M1_ARVALID = (rstate == R_FWD)  && sel_mem_r;
    assign M1_RREADY  = (rstate == R_WAIT_R) && sel_mem_r;

    // Selected-slave response collapse.  Only one port is ever active
    // per path, so this is a select rather than an arbitration.
    wire                  m_aw_hs = (M0_AWVALID && M0_AWREADY) || (M1_AWVALID && M1_AWREADY);
    wire                  m_w_hs  = (M0_WVALID  && M0_WREADY)  || (M1_WVALID  && M1_WREADY);
    wire                  m_b_hs  = (M0_BVALID  && M0_BREADY)  || (M1_BVALID  && M1_BREADY);
    wire                  m_ar_hs = (M0_ARVALID && M0_ARREADY) || (M1_ARVALID && M1_ARREADY);
    wire                  m_r_hs  = (M0_RVALID  && M0_RREADY)  || (M1_RVALID  && M1_RREADY);

    wire [1:0]            m_bresp = sel_mem_w ? M1_BRESP : M0_BRESP;
    wire [DATA_WIDTH-1:0] m_rdata = sel_mem_r ? M1_RDATA : M0_RDATA;
    wire [1:0]            m_rresp = sel_mem_r ? M1_RRESP : M0_RRESP;

    //==================================================================
    // Deliberately unused: the slaves' VALID signals are consumed only
    // through the collapsed handshake wires above.  Named so lint stays
    // clean and the omission reads as intent.
    //==================================================================
    wire _unused_ok = &{1'b0, M0_BVALID, M1_BVALID, M0_RVALID, M1_RVALID, 1'b0};

endmodule : axi4lite_interconnect
