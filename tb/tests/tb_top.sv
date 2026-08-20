//======================================================================
// tb_top.sv
//
// Clock, reset, DUT, and the one config_db::set that hands the virtual
// interface to every component that asks for it.
//
// The DUT and the interface live in the EDA Playground DESIGN pane;
// this module is the last thing in the TESTBENCH pane.
//======================================================================

module tb_top;

    logic ACLK = 1'b0;
    logic ARESETn;

    always #5 ACLK = ~ACLK;          // 100 MHz

    axi4lite_if vif (.ACLK(ACLK), .ARESETn(ARESETn));

    axi4lite_reg_slave dut (
        .ACLK    (ACLK),      .ARESETn (ARESETn),
        .AWADDR  (vif.AWADDR), .AWPROT (vif.AWPROT), .AWVALID(vif.AWVALID), .AWREADY(vif.AWREADY),
        .WDATA   (vif.WDATA),  .WSTRB  (vif.WSTRB),  .WVALID (vif.WVALID),  .WREADY (vif.WREADY),
        .BRESP   (vif.BRESP),  .BVALID (vif.BVALID), .BREADY (vif.BREADY),
        .ARADDR  (vif.ARADDR), .ARPROT (vif.ARPROT), .ARVALID(vif.ARVALID), .ARREADY(vif.ARREADY),
        .RDATA   (vif.RDATA),  .RRESP  (vif.RRESP),  .RVALID (vif.RVALID),  .RREADY (vif.RREADY)
    );

    // Spec §1: asynchronous assert, synchronous deassert on an active
    // edge. The DUT therefore needs no reset synchroniser.
    initial begin
        ARESETn = 1'b0;
        repeat (5) @(posedge ACLK);
        ARESETn <= 1'b1;
    end

    initial begin
        $dumpfile("dump.vcd");
        $dumpvars;
        // "*" because every component wants the same interface. A narrow
        // scope would be wrong here, unlike is_active.
        uvm_config_db #(virtual axi4lite_if)::set(null, "*", "vif", vif);
        run_test("axi_smoke_test");
    end

endmodule : tb_top
