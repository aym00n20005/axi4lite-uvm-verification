//======================================================================
// sanity_tb.sv  —  v0.3
//
// Crude, non-UVM testbench for axi4lite_reg_slave.  Spec §8: "Its only
// job is proving the RTL breathes before UVM goes on top.  Deleted later."
//
// This is NOT verification.  There is no scoreboard, no randomisation, no
// coverage, and no protocol checker.  It is a smoke test whose failure
// means "do not bother running UVM yet".  Its passing means very little.
//
// Timing conventions, so the handshakes are race-free:
//   - the TB drives with non-blocking assignments on posedge, so a signal
//     driven at edge T is stable for the whole of cycle T+1
//   - the TB samples DUT outputs at a posedge, reading the value that was
//     stable during the preceding cycle
//   - ARESETn deasserts on an active clock edge, per spec §1's reset
//     contract, which is why the DUT needs no reset synchroniser
//
// BREADY and RREADY are tied high throughout.  Backpressure is a UVM-era
// concern (F28); tying them high keeps this file about the register
// semantics rather than about flow control.
//======================================================================

`timescale 1ns/1ps

module sanity_tb;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    // Register offsets — spec §5
    localparam logic [31:0] A_CTRL       = 32'h0000_0000;
    localparam logic [31:0] A_STATUS     = 32'h0000_0004;
    localparam logic [31:0] A_CONFIG     = 32'h0000_0008;
    localparam logic [31:0] A_INT_ENABLE = 32'h0000_000C;
    localparam logic [31:0] A_INT_STATUS = 32'h0000_0010;
    localparam logic [31:0] A_SCRATCH    = 32'h0000_0014;
    localparam logic [31:0] A_COUNTER    = 32'h0000_0018;
    localparam logic [31:0] A_ID         = 32'h0000_001C;

    logic        ACLK, ARESETn;

    logic [31:0] AWADDR;  logic [2:0] AWPROT;  logic AWVALID, AWREADY;
    logic [31:0] WDATA;   logic [3:0] WSTRB;   logic WVALID,  WREADY;
    logic [1:0]  BRESP;                        logic BVALID,  BREADY;
    logic [31:0] ARADDR;  logic [2:0] ARPROT;  logic ARVALID, ARREADY;
    logic [31:0] RDATA;   logic [1:0] RRESP;   logic RVALID,  RREADY;

    axi4lite_reg_slave dut (.*);

    initial ACLK = 1'b0;
    always #5 ACLK = ~ACLK;              // 100 MHz

    // Results of the most recent transaction
    logic [1:0]  b_resp;
    logic [31:0] r_data;
    logic [1:0]  r_resp;

    int errors = 0;
    int checks = 0;

    //==================================================================
    // Checking
    //==================================================================
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

    task automatic check_true(input string name, input bit ok, input logic [31:0] got);
        checks++;
        if (ok) begin
            $display("  PASS   %-44s 0x%08x", name, got);
        end else begin
            errors++;
            $display("  FAIL   %-44s 0x%08x", name, got);
        end
    endtask

    //==================================================================
    // Per-channel drivers.  Separate tasks, driven from separate fork
    // branches, so AW and W are genuinely independent — spec §3 rule 4.
    // A single sequential task could never produce W-before-AW.
    //==================================================================
    task automatic drive_aw(input logic [31:0] addr);
        @(posedge ACLK);
        AWADDR  <= addr;
        AWPROT  <= 3'b000;
        AWVALID <= 1'b1;
        forever begin
            @(posedge ACLK);
            if (AWREADY) break;          // VALID held until READY sampled high
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
            if (BVALID) begin
                b_resp = BRESP;
                break;
            end
        end
    endtask

    task automatic await_r();
        forever begin
            @(posedge ACLK);
            if (RVALID) begin
                r_data = RDATA;
                r_resp = RRESP;
                break;
            end
        end
    endtask

    //==================================================================
    // Transactions.  aw_delay / w_delay let a test choose the ordering:
    //   (0,0) same cycle · (0,n) AW first · (n,0) W first
    //==================================================================
    task automatic axi_write(input logic [31:0] addr,
                             input logic [31:0] data,
                             input logic [3:0]  strb,
                             input int          aw_delay,
                             input int          w_delay);
        fork
            begin repeat (aw_delay) @(posedge ACLK); drive_aw(addr);       end
            begin repeat (w_delay)  @(posedge ACLK); drive_w(data, strb);  end
            await_b();
        join
    endtask

    task automatic axi_read(input logic [31:0] addr);
        fork
            drive_ar(addr);
            await_r();
        join
    endtask

    //==================================================================
    // Stimulus
    //==================================================================
    initial begin
        $dumpfile("sim/sanity_tb.vcd");
        $dumpvars(0, sanity_tb);

        ARESETn = 1'b0;
        AWADDR  = '0; AWPROT = '0; AWVALID = 1'b0;
        WDATA   = '0; WSTRB  = '0; WVALID  = 1'b0;
        ARADDR  = '0; ARPROT = '0; ARVALID = 1'b0;
        BREADY  = 1'b1;
        RREADY  = 1'b1;

        repeat (5) @(posedge ACLK);
        ARESETn <= 1'b1;                 // deassert on an active edge, spec §1
        repeat (2) @(posedge ACLK);

        $display("");
        $display("========================================================================");
        $display(" sanity_tb — axi4lite_reg_slave, spec v0.3");
        $display("========================================================================");

        //--------------------------------------------------------------
        $display("\n-- reset values and constants (spec §5) --");

        axi_read(A_ID);
        check("ID reads 0xDEADBEEF",              r_data, 32'hDEAD_BEEF);
        check("ID read response OKAY",     {30'b0, r_resp}, {30'b0, RESP_OKAY});

        axi_read(A_CONFIG);
        check("CONFIG reset value 0x000000FF",    r_data, 32'h0000_00FF);

        axi_read(A_STATUS);
        check("STATUS reads 0 when idle",         r_data, 32'h0000_0000);

        //--------------------------------------------------------------
        $display("\n-- basic write/read, AW and W in the same cycle --");

        axi_write(A_SCRATCH, 32'hDEAD_C0DE, 4'b1111, 0, 0);
        check("SCRATCH write response OKAY", {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(A_SCRATCH);
        check("SCRATCH reads back",               r_data, 32'hDEAD_C0DE);

        //--------------------------------------------------------------
        // Both separated orderings (F03).  W-before-AW is the one a
        // lockstep driver can never produce, spec §3 rule 4.  AW-before-W
        // matters too: it is the only ordering in which a slave can
        // assert BVALID after AW alone, which is BUG-002.
        $display("\n-- W accepted three cycles BEFORE AW --");

        axi_write(A_SCRATCH, 32'h1234_5678, 4'b1111, 3, 0);
        check("W-before-AW response OKAY",   {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(A_SCRATCH);
        check("W-before-AW data landed",          r_data, 32'h1234_5678);

        $display("\n-- AW accepted three cycles BEFORE W --");

        axi_write(A_SCRATCH, 32'h0F0F_0F0F, 4'b1111, 0, 3);
        check("AW-before-W response OKAY",   {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(A_SCRATCH);
        check("AW-before-W data landed",          r_data, 32'h0F0F_0F0F);

        //--------------------------------------------------------------
        $display("\n-- reserved bits read 0 and cannot store data (F13) --");

        axi_write(A_CONFIG, 32'hFFFF_FFFF, 4'b1111, 0, 0);
        check("CONFIG write response OKAY",  {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(A_CONFIG);
        check("CONFIG masks to 0x000000FF",       r_data, 32'h0000_00FF);

        //--------------------------------------------------------------
        $display("\n-- writes to RO registers: OKAY, discarded (spec §5) --");

        axi_write(A_ID, 32'h0000_0000, 4'b1111, 0, 0);
        check("RO write returns OKAY",       {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(A_ID);
        check("RO register unchanged",            r_data, 32'hDEAD_BEEF);

        //--------------------------------------------------------------
        // Three things in one transaction, per spec §5.
        $display("\n-- partial-strobe register write (F16) --");

        axi_write(A_SCRATCH, 32'hAAAA_AAAA, 4'b0011, 0, 0);
        check("partial strobe -> SLVERR",    {30'b0, b_resp}, {30'b0, RESP_SLVERR});
        axi_read(A_SCRATCH);
        check("register unchanged by error",      r_data, 32'h0F0F_0F0F);
        axi_read(A_INT_STATUS);
        check("INT_STATUS[2] set",                r_data, 32'h0000_0004);

        //--------------------------------------------------------------
        // This is the spec v0.3 decode fix under test.  With the v0.2
        // "ADDR[7:2]" decode, 0x100 would have aliased onto CTRL and
        // returned OKAY.
        $display("\n-- unimplemented offset 0x100 (F19, spec v0.3 rev 1) --");

        axi_write(32'h0000_0100, 32'hFFFF_FFFF, 4'b1111, 0, 0);
        check("offset 0x100 -> SLVERR",      {30'b0, b_resp}, {30'b0, RESP_SLVERR});
        axi_read(A_CTRL);
        check("CTRL not aliased by 0x100",        r_data, 32'h0000_0000);

        //--------------------------------------------------------------
        $display("\n-- misaligned access (F20) --");

        axi_read(32'h0000_0006);
        check("misaligned read -> SLVERR",   {30'b0, r_resp}, {30'b0, RESP_SLVERR});
        check("RDATA zeroed on error",            r_data, 32'h0000_0000);

        axi_write(32'h0000_0006, 32'hFFFF_FFFF, 4'b1111, 0, 0);
        check("misaligned write -> SLVERR",  {30'b0, b_resp}, {30'b0, RESP_SLVERR});

        //--------------------------------------------------------------
        // Contrast with the memory slave, where 4'b0000 is a legal no-op
        // returning OKAY (spec §6).  On the register slave it is an
        // error like any other partial strobe (spec §5).
        $display("\n-- zero strobe on a register write (spec §5) --");

        axi_write(A_SCRATCH, 32'hFFFF_FFFF, 4'b0000, 0, 0);
        check("WSTRB=0000 -> SLVERR",        {30'b0, b_resp}, {30'b0, RESP_SLVERR});
        axi_read(A_SCRATCH);
        check("SCRATCH unchanged by 0-strobe",    r_data, 32'h0F0F_0F0F);

        //--------------------------------------------------------------
        $display("\n-- W1C semantics (F12, spec §5 example) --");

        axi_read(A_INT_STATUS);
        check("INT_STATUS accumulated 0b0111",    r_data, 32'h0000_0007);

        // Write 0b0101: clears bits 0 and 2, leaves bit 1 untouched.
        axi_write(A_INT_STATUS, 32'h0000_0005, 4'b1111, 0, 0);
        check("W1C write OKAY",              {30'b0, b_resp}, {30'b0, RESP_OKAY});
        axi_read(A_INT_STATUS);
        check("W1C cleared only bits 0 and 2",    r_data, 32'h0000_0002);

        //--------------------------------------------------------------
        $display("\n-- COUNTER and reset_stats (F26) --");

        axi_write(A_CTRL, 32'h0000_0001, 4'b1111, 0, 0);   // enable = 1
        repeat (20) @(posedge ACLK);
        axi_read(A_COUNTER);
        check_true("COUNTER increments while enabled", r_data > 32'd20, r_data);
        check_true("COUNTER stays within 16 bits",     r_data <= 32'hFFFF, r_data);

        axi_write(A_CTRL, 32'h0000_0002, 4'b1111, 0, 0);   // reset_stats, enable = 0
        axi_read(A_COUNTER);
        check("reset_stats clears COUNTER",       r_data, 32'h0000_0000);

        // enable and reset_stats together: counter clears, enable survives,
        // and reset_stats itself reads back 0 (spec §5, clarified in v0.3).
        axi_write(A_CTRL, 32'h0000_0003, 4'b1111, 0, 0);
        axi_read(A_CTRL);
        check("reset_stats reads 0, enable set",  r_data, 32'h0000_0001);

        //--------------------------------------------------------------
        $display("");
        $display("========================================================================");
        if (errors == 0)
            $display(" RESULT: all %0d checks passed", checks);
        else
            $display(" RESULT: %0d of %0d checks FAILED", errors, checks);
        $display("========================================================================");
        $display("");

        if (errors != 0) $fatal(1, "sanity_tb failed");
        $finish;
    end

    //==================================================================
    // Watchdog.  A hung handshake is the most likely early failure, and
    // without this the simulation just stops producing output.
    //==================================================================
    initial begin
        #200000;
        $display("\n  TIMEOUT — a handshake never completed\n");
        $fatal(1, "sanity_tb timeout");
    end

endmodule : sanity_tb
