//======================================================================
// sanity_mem_tb.sv  —  v0.3
//
// Crude, non-UVM smoke bench for axi4lite_mem_slave.  Companion to
// sanity_tb.sv; spec §8, deleted once UVM is in place.
//
// The driver tasks are duplicated from sanity_tb.sv rather than shared.
// That is deliberate for a throwaway bench: each file runs standalone
// with no include order to get right, and both disappear together.
//
// What this bench is really for is the three places the memory slave
// behaves OPPOSITELY to the register slave:
//
//   - WSTRB is honoured, byte by byte, instead of being rejected
//   - WSTRB == 4'b0000 is a legal OKAY no-op, not an error
//   - reset does not clear the array
//
// The last one is the reason spec §6 states it explicitly: surviving
// data after reset looks exactly like a bug until you know it is
// required.
//======================================================================

`timescale 1ns/1ps

module sanity_mem_tb;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    localparam logic [31:0] MEM_BASE = 32'h0000_1000;
    localparam logic [31:0] W000     = MEM_BASE + 32'h000;   // word 0
    localparam logic [31:0] W005     = MEM_BASE + 32'h014;   // word 5
    localparam logic [31:0] W255     = MEM_BASE + 32'h3FC;   // word 255, last

    logic        ACLK, ARESETn;

    logic [31:0] AWADDR;  logic [2:0] AWPROT;  logic AWVALID, AWREADY;
    logic [31:0] WDATA;   logic [3:0] WSTRB;   logic WVALID,  WREADY;
    logic [1:0]  BRESP;                        logic BVALID,  BREADY;
    logic [31:0] ARADDR;  logic [2:0] ARPROT;  logic ARVALID, ARREADY;
    logic [31:0] RDATA;   logic [1:0] RRESP;   logic RVALID,  RREADY;

    axi4lite_mem_slave dut (.*);

    initial ACLK = 1'b0;
    always #5 ACLK = ~ACLK;

    logic [1:0]  b_resp;
    logic [31:0] r_data;
    logic [1:0]  r_resp;

    int errors = 0;
    int checks = 0;

    task automatic check(input string name,
                         input logic [31:0] got,
                         input logic [31:0] exp);
        checks++;
        if (got === exp) begin
            $display("  PASS   %-44s 0x%08x", name, got);
        end else begin
            errors++;
            $display("  FAIL   %-44s 0x%08x  (expected 0x%08x)", name, got, exp);
        end
    endtask

    //==================================================================
    // Per-channel drivers
    //==================================================================
    task automatic drive_aw(input logic [31:0] addr);
        @(posedge ACLK);
        AWADDR  <= addr;
        AWPROT  <= 3'b000;
        AWVALID <= 1'b1;
        forever begin
            @(posedge ACLK);
            if (AWREADY) break;
        end
        AWVALID <= 1'b0;
    endtask

    task automatic drive_w(input logic [31:0] data, input logic [3:0] strb);
        @(posedge ACLK);
        WDATA  <= data;
        WSTRB  <= strb;
        WVALID <= 1'b1;
        forever begin
            @(posedge ACLK);
            if (WREADY) break;
        end
        WVALID <= 1'b0;
    endtask

    task automatic drive_ar(input logic [31:0] addr);
        @(posedge ACLK);
        ARADDR  <= addr;
        ARPROT  <= 3'b000;
        ARVALID <= 1'b1;
        forever begin
            @(posedge ACLK);
            if (ARREADY) break;
        end
        ARVALID <= 1'b0;
    endtask

    task automatic await_b();
        forever begin
            @(posedge ACLK);
            if (BVALID) begin b_resp = BRESP; break; end
        end
    endtask

    task automatic await_r();
        forever begin
            @(posedge ACLK);
            if (RVALID) begin r_data = RDATA; r_resp = RRESP; break; end
        end
    endtask

    task automatic axi_write(input logic [31:0] addr,
                             input logic [31:0] data,
                             input logic [3:0]  strb,
                             input int          aw_delay,
                             input int          w_delay);
        fork
            begin repeat (aw_delay) @(posedge ACLK); drive_aw(addr);      end
            begin repeat (w_delay)  @(posedge ACLK); drive_w(data, strb); end
            await_b();
        join
    endtask

    task automatic axi_read(input logic [31:0] addr);
        fork
            drive_ar(addr);
            await_r();
        join
    endtask

    // Async assert, synchronous deassert on an active edge — spec §1.
    task automatic pulse_reset();
        ARESETn <= 1'b0;
        repeat (3) @(posedge ACLK);
        ARESETn <= 1'b1;
        repeat (2) @(posedge ACLK);
    endtask

    //==================================================================
    // Stimulus
    //==================================================================
    initial begin
        $dumpfile("sim/sanity_mem_tb.vcd");
        $dumpvars(0, sanity_mem_tb);

        ARESETn = 1'b0;
        AWADDR  = '0; AWPROT = '0; AWVALID = 1'b0;
        WDATA   = '0; WSTRB  = '0; WVALID  = 1'b0;
        ARADDR  = '0; ARPROT = '0; ARVALID = 1'b0;
        BREADY  = 1'b1;
        RREADY  = 1'b1;

        repeat (5) @(posedge ACLK);
        ARESETn <= 1'b1;
        repeat (2) @(posedge ACLK);

        $display("");
        $display("========================================================================");
        $display(" sanity_mem_tb — axi4lite_mem_slave, spec v0.3 §6");
        $display("========================================================================");

        //--------------------------------------------------------------
        $display("\n-- full word access at both ends of the region (F14) --");

        axi_write(W000, 32'hCAFE_BABE, 4'b1111, 0, 0);
        check("word 0 write OKAY",           {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(W000);
        check("word 0 reads back",                r_data, 32'hCAFE_BABE);

        axi_write(W255, 32'h5A5A_A5A5, 4'b1111, 0, 0);
        check("word 255 write OKAY",         {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(W255);
        check("word 255 reads back",              r_data, 32'h5A5A_A5A5);

        axi_read(W000);
        check("word 0 undisturbed by word 255",   r_data, 32'hCAFE_BABE);

        //--------------------------------------------------------------
        // Cumulative: each lane must land on its own byte and disturb
        // nothing else.  Getting the lane-to-byte mapping backwards is
        // the obvious bug here, and this sequence pins it exactly.
        $display("\n-- byte lanes, one at a time (F15) --");

        axi_write(W005, 32'h0000_0000, 4'b1111, 0, 0);
        axi_read(W005);
        check("cleared to zero",                  r_data, 32'h0000_0000);

        axi_write(W005, 32'hAABB_CCDD, 4'b0001, 0, 0);
        axi_read(W005);
        check("WSTRB=0001 writes byte 0 only",    r_data, 32'h0000_00DD);

        axi_write(W005, 32'hAABB_CCDD, 4'b0010, 0, 0);
        axi_read(W005);
        check("WSTRB=0010 writes byte 1 only",    r_data, 32'h0000_CCDD);

        axi_write(W005, 32'hAABB_CCDD, 4'b0100, 0, 0);
        axi_read(W005);
        check("WSTRB=0100 writes byte 2 only",    r_data, 32'h00BB_CCDD);

        axi_write(W005, 32'hAABB_CCDD, 4'b1000, 0, 0);
        axi_read(W005);
        check("WSTRB=1000 writes byte 3 only",    r_data, 32'hAABB_CCDD);

        //--------------------------------------------------------------
        $display("\n-- non-contiguous strobe --");

        axi_write(W005, 32'h1122_3344, 4'b1010, 0, 0);
        check("split strobe OKAY",           {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(W005);
        check("only bytes 1 and 3 changed",       r_data, 32'h11BB_33DD);

        //--------------------------------------------------------------
        // The contrast that matters.  Identical stimulus on the register
        // slave returns SLVERR and sets INT_STATUS[2] (spec §5).
        $display("\n-- WSTRB=0000 is a legal no-op here (spec §6) --");

        axi_write(W005, 32'hFFFF_FFFF, 4'b0000, 0, 0);
        check("zero strobe returns OKAY",    {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(W005);
        check("memory unchanged by zero strobe",  r_data, 32'h11BB_33DD);

        //--------------------------------------------------------------
        $display("\n-- misaligned access, bus-error only (F20) --");

        axi_write(MEM_BASE + 32'h016, 32'hDEAD_DEAD, 4'b1111, 0, 0);
        check("misaligned write -> SLVERR",  {30'b0, b_resp}, {30'b0, RESP_SLVERR});
        axi_read(W005);
        check("no state change on misaligned",    r_data, 32'h11BB_33DD);

        axi_read(MEM_BASE + 32'h016);
        check("misaligned read -> SLVERR",   {30'b0, r_resp}, {30'b0, RESP_SLVERR});
        check("RDATA zeroed on error",            r_data, 32'h0000_0000);

        //--------------------------------------------------------------
        $display("\n-- AW/W ordering independence (F03) --");

        axi_write(W005, 32'h0F0F_0F0F, 4'b1111, 3, 0);   // W first
        check("W-before-AW OKAY",            {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(W005);
        check("W-before-AW data landed",          r_data, 32'h0F0F_0F0F);

        axi_write(W005, 32'hF0F0_F0F0, 4'b1111, 0, 3);   // AW first
        check("AW-before-W OKAY",            {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(W005);
        check("AW-before-W data landed",          r_data, 32'hF0F0_F0F0);

        //--------------------------------------------------------------
        // Spec §6: "Reset does not clear memory contents.  This matches
        // real RAM and is stated explicitly so it isn't mistaken for a
        // bug during scoreboard bring-up."  Asserting it here means the
        // requirement is tested rather than merely written down.
        $display("\n-- reset does NOT clear the array (spec §6) --");

        pulse_reset();

        axi_read(W005);
        check("word 5 survives reset",            r_data, 32'hF0F0_F0F0);
        axi_read(W000);
        check("word 0 survives reset",            r_data, 32'hCAFE_BABE);
        axi_read(W255);
        check("word 255 survives reset",          r_data, 32'h5A5A_A5A5);

        // ...but the protocol state machine IS reset and still works.
        axi_write(W000, 32'h1357_9BDF, 4'b1111, 0, 0);
        check("write works after reset",     {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(W000);
        check("read works after reset",           r_data, 32'h1357_9BDF);

        //--------------------------------------------------------------
        $display("");
        $display("========================================================================");
        if (errors == 0)
            $display(" RESULT: all %0d checks passed", checks);
        else
            $display(" RESULT: %0d of %0d checks FAILED", errors, checks);
        $display("========================================================================");
        $display("");

        if (errors != 0) $fatal(1, "sanity_mem_tb failed");
        $finish;
    end

    initial begin
        #200000;
        $display("\n  TIMEOUT — a handshake never completed\n");
        $fatal(1, "sanity_mem_tb timeout");
    end

endmodule : sanity_mem_tb
