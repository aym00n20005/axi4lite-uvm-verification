//======================================================================
// sanity_sys_tb.sv
//
// Non-UVM bench for the interconnect + both slaves.  The first thing in
// this project that can prove DECERR, and it proves it LOCALLY, under
// the free tool, with all three bound checker instances live.
//
// (No comment line here starts with the tool's name. A `//` comment
// whose first word is "verilator" is read as a PRAGMA, and an unknown
// one is a hard error -- BADVLTPRAGMA. Worth knowing once.)
//
// Why that matters more than the checks themselves: docs/coverage_status.md
// justified three open cg_address_region bins and the cg_response DECERR
// bin with one cause -- "there is no interconnect, so no address decode
// exists to route a transaction to the memory slave or to terminate an
// unmapped one".  That justification was correct and is now spent.  The
// cover property c_resp_decerr has read 0 in every run this project has
// ever made; this bench is where it stops being 0, and it does so without
// a commercial simulator.
//
// SCOPE.  Same as sanity_tb: no scoreboard, no randomisation, no
// coverage model.  A smoke test whose failure means "do not bother
// running UVM yet".  The UVM environment does the verification; this
// establishes that routing works at all, and gives the local regression
// something with a decode in it to randomise against.
//
// Conventions are sanity_tb's, unchanged: non-blocking drives on posedge,
// samples at a posedge, reset deasserted on an active edge per spec
// section 1.  BREADY/RREADY tied high -- backpressure is sanity_rand_tb's job.
//======================================================================

`timescale 1ns/1ps

module sanity_sys_tb;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    // Spec section 4 address map, written from the SPEC and not from the
    // interconnect's localparams.  A bench that imports the DUT's own
    // constants agrees with the DUT by construction.
    localparam logic [31:0] A_CTRL       = 32'h0000_0000;
    localparam logic [31:0] A_SCRATCH    = 32'h0000_0014;
    localparam logic [31:0] A_ID         = 32'h0000_001C;
    localparam logic [31:0] A_REG_UNIMPL = 32'h0000_0100;   // decoded, unimplemented
    localparam logic [31:0] A_REG_TOP    = 32'h0000_0FFC;   // last register-region word
    localparam logic [31:0] A_MEM_0      = 32'h0000_1000;   // memory word 0
    localparam logic [31:0] A_MEM_255    = 32'h0000_13FC;   // memory word 255, last mapped
    localparam logic [31:0] A_GAP_LO     = 32'h0000_1400;   // FIRST unmapped address
    localparam logic [31:0] A_GAP_HI     = 32'h0000_1FFC;   // last of the deliberate gap
    localparam logic [31:0] A_UNMAP_HI   = 32'hDEAD_0000;   // unmapped, high

    logic ACLK, ARESETn;

    // Master-facing bus
    logic [31:0] AWADDR;  logic [2:0] AWPROT;  logic AWVALID, AWREADY;
    logic [31:0] WDATA;   logic [3:0] WSTRB;   logic WVALID,  WREADY;
    logic [1:0]  BRESP;                        logic BVALID,  BREADY;
    logic [31:0] ARADDR;  logic [2:0] ARPROT;  logic ARVALID, ARREADY;
    logic [31:0] RDATA;   logic [1:0] RRESP;   logic RVALID,  RREADY;

    // Interconnect <-> slaves
    logic [31:0] m0_awaddr, m1_awaddr;  logic [2:0] m0_awprot, m1_awprot;
    logic        m0_awvalid, m1_awvalid, m0_awready, m1_awready;
    logic [31:0] m0_wdata,  m1_wdata;   logic [3:0] m0_wstrb,  m1_wstrb;
    logic        m0_wvalid, m1_wvalid,  m0_wready,  m1_wready;
    logic [1:0]  m0_bresp,  m1_bresp;   logic m0_bvalid, m1_bvalid, m0_bready, m1_bready;
    logic [31:0] m0_araddr, m1_araddr;  logic [2:0] m0_arprot, m1_arprot;
    logic        m0_arvalid, m1_arvalid, m0_arready, m1_arready;
    logic [31:0] m0_rdata,  m1_rdata;   logic [1:0] m0_rresp,  m1_rresp;
    logic        m0_rvalid, m1_rvalid,  m0_rready,  m1_rready;

    axi4lite_interconnect u_ic (
        .ACLK, .ARESETn,
        .S_AWADDR(AWADDR), .S_AWPROT(AWPROT), .S_AWVALID(AWVALID), .S_AWREADY(AWREADY),
        .S_WDATA (WDATA),  .S_WSTRB (WSTRB),  .S_WVALID (WVALID),  .S_WREADY (WREADY),
        .S_BRESP (BRESP),  .S_BVALID(BVALID), .S_BREADY (BREADY),
        .S_ARADDR(ARADDR), .S_ARPROT(ARPROT), .S_ARVALID(ARVALID), .S_ARREADY(ARREADY),
        .S_RDATA (RDATA),  .S_RRESP (RRESP),  .S_RVALID (RVALID),  .S_RREADY (RREADY),

        .M0_AWADDR(m0_awaddr), .M0_AWPROT(m0_awprot), .M0_AWVALID(m0_awvalid), .M0_AWREADY(m0_awready),
        .M0_WDATA (m0_wdata),  .M0_WSTRB (m0_wstrb),  .M0_WVALID (m0_wvalid),  .M0_WREADY (m0_wready),
        .M0_BRESP (m0_bresp),  .M0_BVALID(m0_bvalid), .M0_BREADY (m0_bready),
        .M0_ARADDR(m0_araddr), .M0_ARPROT(m0_arprot), .M0_ARVALID(m0_arvalid), .M0_ARREADY(m0_arready),
        .M0_RDATA (m0_rdata),  .M0_RRESP (m0_rresp),  .M0_RVALID (m0_rvalid),  .M0_RREADY (m0_rready),

        .M1_AWADDR(m1_awaddr), .M1_AWPROT(m1_awprot), .M1_AWVALID(m1_awvalid), .M1_AWREADY(m1_awready),
        .M1_WDATA (m1_wdata),  .M1_WSTRB (m1_wstrb),  .M1_WVALID (m1_wvalid),  .M1_WREADY (m1_wready),
        .M1_BRESP (m1_bresp),  .M1_BVALID(m1_bvalid), .M1_BREADY (m1_bready),
        .M1_ARADDR(m1_araddr), .M1_ARPROT(m1_arprot), .M1_ARVALID(m1_arvalid), .M1_ARREADY(m1_arready),
        .M1_RDATA (m1_rdata),  .M1_RRESP (m1_rresp),  .M1_RVALID (m1_rvalid),  .M1_RREADY (m1_rready)
    );

    axi4lite_reg_slave u_reg (
        .ACLK, .ARESETn,
        .AWADDR(m0_awaddr), .AWPROT(m0_awprot), .AWVALID(m0_awvalid), .AWREADY(m0_awready),
        .WDATA (m0_wdata),  .WSTRB (m0_wstrb),  .WVALID (m0_wvalid),  .WREADY (m0_wready),
        .BRESP (m0_bresp),  .BVALID(m0_bvalid), .BREADY (m0_bready),
        .ARADDR(m0_araddr), .ARPROT(m0_arprot), .ARVALID(m0_arvalid), .ARREADY(m0_arready),
        .RDATA (m0_rdata),  .RRESP (m0_rresp),  .RVALID (m0_rvalid),  .RREADY (m0_rready)
    );

    axi4lite_mem_slave u_mem (
        .ACLK, .ARESETn,
        .AWADDR(m1_awaddr), .AWPROT(m1_awprot), .AWVALID(m1_awvalid), .AWREADY(m1_awready),
        .WDATA (m1_wdata),  .WSTRB (m1_wstrb),  .WVALID (m1_wvalid),  .WREADY (m1_wready),
        .BRESP (m1_bresp),  .BVALID(m1_bvalid), .BREADY (m1_bready),
        .ARADDR(m1_araddr), .ARPROT(m1_arprot), .ARVALID(m1_arvalid), .ARREADY(m1_arready),
        .RDATA (m1_rdata),  .RRESP (m1_rresp),  .RVALID (m1_rvalid),  .RREADY (m1_rready)
    );

    initial ACLK = 1'b0;
    always #5 ACLK = ~ACLK;

    logic [1:0]  b_resp;
    logic [31:0] r_data;
    logic [1:0]  r_resp;

    int errors = 0;
    int checks = 0;

    task automatic check(input string name, input logic [31:0] got, input logic [31:0] exp);
        checks++;
        if (got === exp) $display("  PASS   %-44s 0x%08x", name, got);
        else begin
            errors++;
            $display("  FAIL   %-44s 0x%08x  (expected 0x%08x)", name, got, exp);
        end
    endtask

    //==================================================================
    // Per-channel drivers, one fork branch each -- spec section 3 rule 4.
    //==================================================================
    task automatic drive_aw(input logic [31:0] addr);
        @(posedge ACLK);
        AWADDR <= addr; AWPROT <= 3'b000; AWVALID <= 1'b1;
        forever begin @(posedge ACLK); if (AWREADY) break; end
        AWVALID <= 1'b0;
    endtask

    task automatic drive_w(input logic [31:0] data, input logic [3:0] strb);
        @(posedge ACLK);
        WDATA <= data; WSTRB <= strb; WVALID <= 1'b1;
        forever begin @(posedge ACLK); if (WREADY) break; end
        WVALID <= 1'b0;
    endtask

    task automatic drive_ar(input logic [31:0] addr);
        @(posedge ACLK);
        ARADDR <= addr; ARPROT <= 3'b000; ARVALID <= 1'b1;
        forever begin @(posedge ACLK); if (ARREADY) break; end
        ARVALID <= 1'b0;
    endtask

    task automatic await_b();
        forever begin @(posedge ACLK); if (BVALID) begin b_resp = BRESP; break; end end
    endtask

    task automatic await_r();
        forever begin
            @(posedge ACLK);
            if (RVALID) begin r_data = RDATA; r_resp = RRESP; break; end
        end
    endtask

    task automatic axi_write(input logic [31:0] addr, input logic [31:0] data,
                             input logic [3:0] strb, input int aw_delay, input int w_delay);
        fork
            begin repeat (aw_delay) @(posedge ACLK); drive_aw(addr);      end
            begin repeat (w_delay)  @(posedge ACLK); drive_w(data, strb); end
            await_b();
        join
    endtask

    task automatic axi_read(input logic [31:0] addr);
        fork drive_ar(addr); await_r(); join
    endtask

    //==================================================================
    initial begin
        ARESETn = 1'b0;
        AWADDR = '0; AWPROT = '0; AWVALID = 1'b0;
        WDATA  = '0; WSTRB  = '0; WVALID  = 1'b0;
        ARADDR = '0; ARPROT = '0; ARVALID = 1'b0;
        BREADY = 1'b1;
        RREADY = 1'b1;

        repeat (5) @(posedge ACLK);
        ARESETn <= 1'b1;
        repeat (2) @(posedge ACLK);

        $display("");
        $display("========================================================================");
        $display(" sanity_sys_tb -- interconnect + both slaves, spec v0.3 section 4 and 7");
        $display("========================================================================");

        //--------------------------------------------------------------
        $display("\n-- routing to the register slave (F17) --");

        axi_read(A_ID);
        check("0x0000001C reaches the register slave", r_data, 32'hDEAD_BEEF);
        check("  response OKAY",              {30'b0, r_resp}, {30'b0, RESP_OKAY});

        axi_write(A_SCRATCH, 32'hCAFE_F00D, 4'b1111, 0, 0);
        check("SCRATCH write routed, OKAY",   {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(A_SCRATCH);
        check("SCRATCH reads back",                    r_data, 32'hCAFE_F00D);

        //--------------------------------------------------------------
        // The whole reason the decode is a range comparison. Under a
        // naive ADDR[12] decode 0x1000 and 0x1400 route identically.
        $display("\n-- routing to the memory slave (F17) --");

        axi_write(A_MEM_0, 32'h1111_2222, 4'b1111, 0, 0);
        check("memory word 0 write OKAY",     {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(A_MEM_0);
        check("memory word 0 reads back",              r_data, 32'h1111_2222);

        axi_write(A_MEM_255, 32'h3333_4444, 4'b1111, 0, 0);
        check("memory word 255 write OKAY",   {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(A_MEM_255);
        check("memory word 255 reads back",            r_data, 32'h3333_4444);

        // Proof the two slaves are actually distinct devices and not one
        // aliased decode: same low bits, different region, different data.
        axi_read(A_SCRATCH);
        check("register SCRATCH unchanged by memory",   r_data, 32'hCAFE_F00D);

        //--------------------------------------------------------------
        $display("\n-- the deliberate gap: DECERR (F18) --");

        // 0x1400 is the FIRST unmapped address and the one that matters:
        // it is immediately above memory, and inside what ADDR[12] alone
        // would route to memory. Spec section 9 BUG-005 is exactly this.
        axi_write(A_GAP_LO, 32'hBAAD_BAAD, 4'b1111, 0, 0);
        check("write 0x00001400 -> DECERR",   {30'b0, b_resp}, {30'b0, RESP_DECERR});
        axi_read(A_GAP_LO);
        check("read  0x00001400 -> DECERR",   {30'b0, r_resp}, {30'b0, RESP_DECERR});
        check("  RDATA zeroed on error",               r_data, 32'h0000_0000);

        axi_read(A_GAP_HI);
        check("read  0x00001FFC -> DECERR",   {30'b0, r_resp}, {30'b0, RESP_DECERR});
        axi_read(A_UNMAP_HI);
        check("read  0xDEAD0000 -> DECERR",   {30'b0, r_resp}, {30'b0, RESP_DECERR});

        // Not forwarded. If 0x1400 had reached memory it would have
        // landed on word 0x100 of a 256-word array, which wraps onto
        // word 0 -- so word 0 is the witness.
        axi_read(A_MEM_0);
        check("memory word 0 untouched by DECERR",     r_data, 32'h1111_2222);

        //--------------------------------------------------------------
        // DECERR and SLVERR are different answers to different questions,
        // and the boundary between them is one address apart.
        $display("\n-- DECERR is not SLVERR (spec section 4) --");

        axi_read(A_REG_UNIMPL);
        check("0x00000100 -> SLVERR, not DECERR", {30'b0, r_resp}, {30'b0, RESP_SLVERR});
        axi_read(A_REG_TOP);
        check("0x00000FFC -> SLVERR (region top)", {30'b0, r_resp}, {30'b0, RESP_SLVERR});
        axi_read(A_MEM_0);
        check("0x00001000 -> OKAY (one word later)", {30'b0, r_resp}, {30'b0, RESP_OKAY});
        axi_read(A_MEM_255);
        check("0x000013FC -> OKAY (last mapped)", {30'b0, r_resp}, {30'b0, RESP_OKAY});
        axi_read(A_GAP_LO);
        check("0x00001400 -> DECERR (next word)", {30'b0, r_resp}, {30'b0, RESP_DECERR});

        //--------------------------------------------------------------
        // Spec section 7's hard part: when W arrives first the destination
        // is not yet known, so the beat has to be held.
        $display("\n-- W accepted before AW, across the decode (spec section 7) --");

        axi_write(A_MEM_0, 32'h5555_6666, 4'b1111, 4, 0);
        check("W-before-AW to memory, OKAY",  {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(A_MEM_0);
        check("  held W beat landed in memory",        r_data, 32'h5555_6666);

        axi_write(A_SCRATCH, 32'h7777_8888, 4'b1111, 4, 0);
        check("W-before-AW to registers, OKAY", {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(A_SCRATCH);
        check("  held W beat landed in registers",     r_data, 32'h7777_8888);

        // And the case where the held beat must NOT be forwarded at all.
        axi_write(A_GAP_LO, 32'h9999_AAAA, 4'b1111, 4, 0);
        check("W-before-AW to the gap -> DECERR", {30'b0, b_resp}, {30'b0, RESP_DECERR});
        axi_read(A_MEM_0);
        check("  and nothing was written",             r_data, 32'h5555_6666);
        axi_read(A_SCRATCH);
        check("  to either slave",                     r_data, 32'h7777_8888);

        // AW first, for symmetry.
        axi_write(A_MEM_255, 32'hBBBB_CCCC, 4'b1111, 0, 4);
        check("AW-before-W to memory, OKAY",  {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(A_MEM_255);
        check("  data landed",                         r_data, 32'hBBBB_CCCC);

        //--------------------------------------------------------------
        // Precedence, spec section 4: unmapped outranks misaligned. A
        // misaligned unmapped address is DECERR, not SLVERR, because the
        // interconnect answers before any slave sees it.
        $display("\n-- error precedence across the boundary (F21) --");

        axi_read(A_MEM_0 + 32'd2);
        check("misaligned in memory -> SLVERR", {30'b0, r_resp}, {30'b0, RESP_SLVERR});
        axi_read(A_GAP_LO + 32'd2);
        check("misaligned AND unmapped -> DECERR", {30'b0, r_resp}, {30'b0, RESP_DECERR});
        axi_read(32'h0000_0002);
        check("misaligned in registers -> SLVERR", {30'b0, r_resp}, {30'b0, RESP_SLVERR});

        //--------------------------------------------------------------
        // WSTRB policy is per-slave and the interconnect must not
        // interfere with either. Same strobe, opposite meaning.
        $display("\n-- per-slave WSTRB policy survives routing (F15/F16) --");

        axi_write(A_MEM_0, 32'hFFFF_FFFF, 4'b0010, 0, 0);
        check("partial strobe to memory -> OKAY", {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(A_MEM_0);
        check("  only byte 1 changed",                 r_data, 32'h5555_FF66);

        axi_write(A_SCRATCH, 32'hFFFF_FFFF, 4'b0010, 0, 0);
        check("partial strobe to registers -> SLVERR", {30'b0, b_resp}, {30'b0, RESP_SLVERR});
        axi_read(A_SCRATCH);
        check("  register unchanged",                  r_data, 32'h7777_8888);

        //--------------------------------------------------------------
        $display("");
        $display("========================================================================");
        if (errors == 0) $display(" RESULT: all %0d checks passed", checks);
        else             $display(" RESULT: %0d of %0d checks FAILED", errors, checks);
        $display("========================================================================");
        $display("");

        if (errors != 0) $fatal(1, "sanity_sys_tb failed");
        $finish;
    end

    initial begin
        #200000;
        $display("\n  TIMEOUT -- a handshake never completed\n");
        $fatal(1, "sanity_sys_tb timeout");
    end

endmodule : sanity_sys_tb
