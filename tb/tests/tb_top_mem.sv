//======================================================================
// tb_top_mem.sv
//
// Testbench top for the MEMORY slave. Companion to tb_top.sv.
//
// A second top rather than one top with both slaves, because putting both
// behind an address decode in the testbench would be building the
// interconnect in the wrong place -- September's RTL, written as
// throwaway TB code, and then thrown away. Each top has one DUT.
//
// Everything above the DUT is identical. That is the point: the agent,
// driver, monitor, coverage collector and scoreboard are reused without
// modification, which is the reuse claim the verification plan makes.
// The scoreboard is TOLD which slave it faces, because with no
// interconnect there is no address decode to work it out from -- each
// slave aliases the whole address space onto its own.
//======================================================================

`ifndef AXI_TEST
  `define AXI_TEST "axi_mem_test"
`endif

module tb_top_mem;

    logic ACLK = 1'b0;
    logic ARESETn;

    always #5 ACLK = ~ACLK;          // 100 MHz

    axi4lite_if vif (.ACLK(ACLK), .ARESETn(ARESETn));

    axi4lite_mem_slave dut (
        .ACLK    (ACLK),      .ARESETn (ARESETn),
        .AWADDR  (vif.AWADDR), .AWPROT (vif.AWPROT), .AWVALID(vif.AWVALID), .AWREADY(vif.AWREADY),
        .WDATA   (vif.WDATA),  .WSTRB  (vif.WSTRB),  .WVALID (vif.WVALID),  .WREADY (vif.WREADY),
        .BRESP   (vif.BRESP),  .BVALID (vif.BVALID), .BREADY (vif.BREADY),
        .ARADDR  (vif.ARADDR), .ARPROT (vif.ARPROT), .ARVALID(vif.ARVALID), .ARREADY(vif.ARREADY),
        .RDATA   (vif.RDATA),  .RRESP  (vif.RRESP),  .RVALID (vif.RVALID),  .RREADY (vif.RREADY)
    );

    // Held at 0 from time 0. Without this a_reset_valids_low fails at
    // 5 ns on X -- see tb_top.sv, where the checker caught it first.
    initial begin
        vif.AWVALID = 1'b0;  vif.WVALID = 1'b0;  vif.ARVALID = 1'b0;
        vif.BREADY  = 1'b0;  vif.RREADY = 1'b0;
        vif.AWADDR  = '0;    vif.AWPROT = '0;
        vif.WDATA   = '0;    vif.WSTRB  = '0;
        vif.ARADDR  = '0;    vif.ARPROT = '0;
    end

    // Spec section 1: asynchronous assert, synchronous deassert.
    initial begin
        ARESETn = 1'b0;
        repeat (5) @(posedge ACLK);
        ARESETn <= 1'b1;
    end


    //------------------------------------------------------------------
    // Watchdog.
    //
    // A hang is the one failure mode this environment could not report.
    // EDA Playground kills an over-running job with exit 137 and no
    // message, so a stalled handshake produced no evidence at all. This
    // turns that into a bus-state dump naming the channel that is stuck.
    //
    // Every stall has a signature: VALID high with READY low means the
    // slave is not accepting; both low on a channel that should be busy
    // means the driver never issued.
    //------------------------------------------------------------------
    initial begin
        #50us;
        $display("");
        $display("=================== WATCHDOG ===================");
        $display(" no completion by 50us. ARESETn=%b", ARESETn);
        $display("   AW  VALID=%b READY=%b  ADDR=0x%08h", vif.AWVALID, vif.AWREADY, vif.AWADDR);
        $display("   W   VALID=%b READY=%b  DATA=0x%08h STRB=%04b",
                 vif.WVALID, vif.WREADY, vif.WDATA, vif.WSTRB);
        $display("   B   VALID=%b READY=%b  RESP=%02b", vif.BVALID, vif.BREADY, vif.BRESP);
        $display("   AR  VALID=%b READY=%b  ADDR=0x%08h", vif.ARVALID, vif.ARREADY, vif.ARADDR);
        $display("   R   VALID=%b READY=%b  DATA=0x%08h RESP=%02b",
                 vif.RVALID, vif.RREADY, vif.RDATA, vif.RRESP);
        $display("================================================");
        $fatal(1, "watchdog: bus stalled");
    end

    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_top_mem);
        uvm_config_db #(virtual axi4lite_if)::set(null, "*", "vif", vif);
        uvm_config_db #(axi_slave_kind_e)::set(null, "*", "slave_kind", SLAVE_MEM);
        run_test(`AXI_TEST);
    end

endmodule : tb_top_mem
