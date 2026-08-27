//======================================================================
// tb_top.sv
//
// Clock, reset, DUT, and the one config_db::set that hands the virtual
// interface to every component that asks for it.
//
// The DUT and the interface live in the EDA Playground DESIGN pane;
// this module is the last thing in the TESTBENCH pane.
//======================================================================

`ifndef AXI_TEST
  `define AXI_TEST "axi_smoke_test"
`endif

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

    // Spec section 1: asynchronous assert, synchronous deassert on an active
    // edge. The DUT therefore needs no reset synchroniser.
    initial begin
        ARESETn = 1'b0;
        repeat (5) @(posedge ACLK);
        ARESETn <= 1'b1;
    end

    //------------------------------------------------------------------
    // Hold the master-driven signals at 0 from time 0.
    //
    // Without this, a_reset_valids_low FAILS at 5 ns -- the checker's own
    // report, on the first run of this testbench:
    //
    //   *E,ASRTST (time 5 NS) Assertion tb_top.dut.u_chk.a_reset_valids_low
    //   has failed -- A VALID was high during reset
    //
    // The interface signals are `logic`, so they are X until something
    // drives them. axi_driver::drive_idle() begins with @(vif.master_cb),
    // which means it cannot drive before the FIRST clocking event at 5 ns,
    // applying at 6 ns. The assertion samples at 5 ns and sees X, and !X
    // is X, which is not a pass.
    //
    // a_reset_valids_low is the one assertion that overrides the default
    // `disable iff (!ARESETn)`, precisely so it can watch during reset.
    // It did its job on the first run.
    //
    // This is a blocking assignment at time 0 only; the driver owns these
    // signals through the clocking block from 6 ns onward, so the two
    // never write in the same time step.
    //------------------------------------------------------------------
    initial begin
        vif.AWVALID = 1'b0;
        vif.WVALID  = 1'b0;
        vif.ARVALID = 1'b0;
        vif.BREADY  = 1'b0;
        vif.RREADY  = 1'b0;
        vif.AWADDR  = '0;
        vif.AWPROT  = '0;
        vif.WDATA   = '0;
        vif.WSTRB   = '0;
        vif.ARADDR  = '0;
        vif.ARPROT  = '0;
    end

    initial begin
        $dumpfile("dump.vcd");
        // Scoped to tb_top. A bare $dumpvars probes the UVM package too
        // and produces *W,PRPASZ on its 115200-bit string arrays.
        $dumpvars(0, tb_top);
        // "*" because every component wants the same interface. A narrow
        // scope would be wrong here, unlike is_active.
        uvm_config_db #(virtual axi4lite_if)::set(null, "*", "vif", vif);
        // AXI_TEST is defined by `make playground` per bundle. EDA
        // Playground's command line is fixed, so +UVM_TESTNAME is not
        // available; a define is how a bundle selects its test.
        run_test(`AXI_TEST);
    end

endmodule : tb_top
